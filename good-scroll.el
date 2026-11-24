;;; good-scroll.el --- Good pixel line scrolling -*- lexical-binding: t; -*-

;; Copyright (C) 2021 Benjamin Levy - MIT/X11 License
;; Author: Benjamin Levy <blevy@protonmail.com>
;; Version: 2.0.1
;; Description: Attempt at good pixel-based smooth scrolling in Emacs
;; Homepage: https://github.com/io12/good-scroll.el
;; Package-Requires: ((emacs "27.1"))

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:

;; This package implements smooth scrolling by pixel lines. It attempts to
;; improve upon `pixel-scroll-mode' by adding variable speed.

;;; Code:

(require 'cl-lib)

(require 'good-scroll-bezier)
(require 'good-scroll-linear)

(defgroup good-scroll nil
  "Good pixel line scrolling"
  :group 'scrolling)

(defcustom good-scroll-render-rate 0.02
  "Number of seconds between renders.
This corresponds to the refresh rate of the scrolling animation.
Changes to this option take effect the next time a scroll starts."
  :group 'good-scroll
  :type 'float)

(defcustom good-scroll-duration 0.15
  "Duration of a scroll in seconds."
  :group 'good-scroll
  :type 'float)

(defcustom good-scroll-step 80
  "Number of pixel lines to scroll during a scroll step."
  :group 'good-scroll
  :type 'integer)

(defcustom good-scroll-algorithm #'good-scroll-bezier
  "The scrolling animation algorithm to use.
If implementing your own algorithm, it should be a function with zero arguments.
The function should return a target position in pixel-lines relative to the top
of the window.
See the built-in algorithms for inspiration."
  :group 'good-scroll
  :type '(radio (function-item good-scroll-bezier)
                (function-item good-scroll-linear)
                function))

(defcustom good-scroll-persist-vscroll-line-move t
  "If non-nil, avoid resetting vscroll when `line-move' is called.
Normally, when the user presses a key to move the point,
`line-move' is called, and this resets the vscroll.
If this variable is non-nil, `good-scroll' overrides this behavior.
For changing this variable to take effect, good-scroll mode must be restarted."
  :group 'good-scroll
  :type 'boolean)

(defcustom good-scroll-persist-vscroll-window-scroll t
  "If non-nil, restore a saved vscroll when `window-scroll-functions' is called.
There are aren't many cases where this makes a difference,
but one example is buffers with other buffers embedded inside them,
such as with the polymode package.
For changing this variable to take effect, good-scroll mode must be restarted."
  :group 'good-scroll
  :type 'boolean)

(defcustom good-scroll-inhibit-bidi-during-scroll nil
  "If non-nil, turn off bidirectional text reordering while scrolling.
Every animation frame makes Emacs redraw the whole window,
and reordering bidirectional text is a noticeable part of that cost.
Disabling it (by setting `bidi-display-reordering' to nil in the scrolled
buffer for the duration of the animation) lowered CPU usage by roughly 20%
while scrolling in our measurements.
Left-to-right text looks exactly the same either way.
Text containing right-to-left characters is displayed in logical order
until the animation ends, so leave this nil if you scroll such text."
  :group 'good-scroll
  :type 'boolean)

(defvar good-scroll--debug nil
  "Flag for enabling debug logging and slow assertions.")

(defvar good-scroll--window nil
  "The window scrolled most recently.")

(defvar good-scroll--timer nil
  "Timer for render updates.
This timer only exists while a scroll is in progress.
It is started by `good-scroll-move' and stopped by `good-scroll--render'
once there is nothing left to scroll, so that an idle Emacs
is not woken up (and redisplayed) every `good-scroll-render-rate' seconds.")

(defvar good-scroll-destination nil
  "Destination of the current scroll.
The unit is pixel lines relative to the top of the window.
For example, -12 means scrolling down 12 pixels.")

(defvar good-scroll-traveled nil
  "Number of pixel lines traveled so far in the current scroll.")

(defvar good-scroll-start-time nil
  "Start time of the most recent scroll.")

(defvar good-scroll-direction 0
  "Direction of the most recent scroll.
This should be an integer. Positive means up and negative means down.")

(defvar good-scroll--cached-point-top nil
  "Cached output of `good-scroll--point-top'.
This is modified when scrolling to avoid re-running `good-scroll--point-top'
for performance reasons.")

(defvar good-scroll--prev-point nil
  "The output of `point' after the last render.")

(defvar good-scroll--prev-window-start nil
  "The output of `window-start' after the last render.")

(defvar good-scroll--prev-vscroll nil
  "The output of `(window-vscroll nil t)' after the last render.")

(defvar good-scroll--pre-command-point nil
  "The value of point before the most recent command executed.
This is used to test if a command moved the cursor.")

(defvar good-scroll--bidi-saved nil
  "Saved state of `bidi-display-reordering' during a scroll, or nil.
When `good-scroll-inhibit-bidi-during-scroll' is in effect, this is a list
\(BUFFER LOCAL-P VALUE) that `good-scroll--restore-bidi' uses to undo it.")

;;;###autoload
(define-minor-mode good-scroll-mode
  "Good pixel line scrolling"
  :init-value nil
  :group 'scrolling
  :global t

  (if good-scroll-mode
      ;; Enable major mode
      (progn
        ;; The render timer is started on demand by `good-scroll-move'.
        (setq mwheel-scroll-up-function #'good-scroll-up
              mwheel-scroll-down-function #'good-scroll-down)
        (when good-scroll-persist-vscroll-line-move
          (advice-add 'line-move :around #'good-scroll--advice-line-move))
        (when good-scroll-persist-vscroll-window-scroll
          (add-hook 'window-scroll-functions #'good-scroll--restore-vscroll))
        (add-hook 'pre-command-hook #'good-scroll--pre-command)
        (add-hook 'post-command-hook #'good-scroll--post-command))
    ;; Disable major mode
    (progn
      (setq mwheel-scroll-up-function #'scroll-up
            mwheel-scroll-down-function #'scroll-down)
      (good-scroll--stop-timer)
      (setq good-scroll-destination 0)
      (advice-remove 'line-move #'good-scroll--advice-line-move)
      (remove-hook 'window-scroll-functions #'good-scroll--restore-vscroll)
      (remove-hook 'pre-command-hook #'good-scroll--pre-command)
      (remove-hook 'post-command-hook #'good-scroll--post-command))))

(defun good-scroll--start-timer ()
  "Start the render timer, unless it is already running."
  (unless (and (timerp good-scroll--timer)
               (memq good-scroll--timer timer-list))
    (setq good-scroll--timer
          (run-at-time 0 good-scroll-render-rate #'good-scroll--render))))

(defun good-scroll--stop-timer ()
  "Stop the render timer, if it is running.
This also ends the scroll, so it undoes `good-scroll--inhibit-bidi'."
  (when (timerp good-scroll--timer)
    (cancel-timer good-scroll--timer))
  (setq good-scroll--timer nil)
  (good-scroll--restore-bidi))

(defun good-scroll--inhibit-bidi ()
  "Turn off bidi reordering in the current buffer for the rest of the scroll.
Remember the previous state so `good-scroll--restore-bidi' can undo this.
Do nothing if the current buffer is already handled."
  (unless (eq (car good-scroll--bidi-saved) (current-buffer))
    ;; The window now shows a different buffer than when the scroll began.
    (good-scroll--restore-bidi)
    (setq good-scroll--bidi-saved (list (current-buffer)
                                        (local-variable-p
                                         'bidi-display-reordering)
                                        bidi-display-reordering))
    (setq-local bidi-display-reordering nil)))

(defun good-scroll--restore-bidi ()
  "Undo `good-scroll--inhibit-bidi', if it is in effect."
  (when good-scroll--bidi-saved
    (let ((buffer (nth 0 good-scroll--bidi-saved))
          (local-p (nth 1 good-scroll--bidi-saved))
          (value (nth 2 good-scroll--bidi-saved)))
      (setq good-scroll--bidi-saved nil)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (if local-p
              (setq-local bidi-display-reordering value)
            (kill-local-variable 'bidi-display-reordering)))))))

(defmacro good-scroll--log (string &rest forms)
  "When `good-scroll--debug' is non-nil, log a message.
Use `message' to write a message of the form `CALLER: STRING: FORMS-STRING',
where CALLER is the function's caller
and FORMS-STRING contains the evaluated values of FORMS."
  nil
  (let ((forms (cons 'list (mapcar (lambda (form) `(list ',form ,form)) forms))))
    `(when good-scroll--debug
       (let* ((stringify-form (lambda (form) (format "%s=%s"
                                                     (nth 0 form)
                                                     (nth 1 form))))
              (forms-string (mapconcat stringify-form ,forms ", ")))
         (message "good-scroll: %s: %s" ,string forms-string)))))

(defun good-scroll--window-and-window-start-same-p ()
  "Return whether the window and window start are the same.
If the selected window, and window start is the same as
it was in in the last render, return non-nil.
Otherwise, return nil."
  (and good-scroll--window
       good-scroll--prev-window-start
       (eq good-scroll--window (selected-window))
       (= good-scroll--prev-window-start (window-start))))

(defun good-scroll--restore-vscroll (&rest _args)
  "Restore the saved vscroll value.
If nothing but the vscroll changed since the last render,
restore the previous vscroll value.
This function is used as a hook in `window-scroll-functions'."
  (when (good-scroll--window-and-window-start-same-p)
    (good-scroll--log "restore vscroll" good-scroll--prev-vscroll)
    (set-window-vscroll nil good-scroll--prev-vscroll t)))

(defun good-scroll--pre-command ()
  "This function is called in `pre-command-hook'.
It saves the value of point in `good-scroll--pre-command-point' so that
`good-scroll--post-command' can check whether the most recent command
moved the cursor."
  (setq good-scroll--pre-command-point (point)))

(defun good-scroll--post-command ()
  "This function is called in `post-command-hook'.
If the most recent command made the cursor overlap the top of the window,
set the window's vscroll to zero to avoid the overlap."
  (when (and good-scroll--pre-command-point
             (/= good-scroll--pre-command-point (point))
             (not (zerop (window-vscroll nil t)))
             (good-scroll--point-at-top-p))
    (set-window-vscroll nil 0 t)))

(defmacro good-scroll--slow-assert (form)
  "When `good-scroll--debug' is non-nil, call `assert' on FORM.
This is used instead of `assert' when FORM is expensive to compute
and shouldn't be run normally."
  `(when good-scroll--debug
     (cl-assert ,form)))

(defun good-scroll--point-at-top-p ()
  "Return non-nil if the point is close to the top of the selected window."
  (save-restriction
    ;; Widen in case the window start is outside the visible part of the buffer
    (widen)
    ;; This is equivalent to comparing the absolute line numbers of the point
    ;; and the window start, but it only looks at the text between them
    ;; instead of counting every line from the beginning of the buffer.
    ;; That matters because this runs on every cursor movement command.
    (let ((start (window-start))
          (pt (point)))
      (or (<= pt start)
          (save-excursion
            (goto-char start)
            ;; At most one newline between the window start and the point?
            (skip-chars-forward "^\n" pt)
            (or (>= (point) pt)
                (progn
                  (forward-char 1)
                  (skip-chars-forward "^\n" pt)
                  (>= (point) pt))))))))

(defun good-scroll--window-start-on-first-line-p ()
  "Return non-nil if the window start is on the first line of the buffer.
\"First line\" means the first line of the accessible part of the buffer.
This does not count lines, so its cost does not grow with the buffer size."
  (save-excursion
    (goto-char (window-start))
    (skip-chars-backward "^\n" (point-min))
    (= (point) (point-min))))

(defun good-scroll--window-start-on-last-line-p ()
  "Return non-nil if the window start is on the last line of the buffer.
\"Last line\" means the last line of the accessible part of the buffer.
This does not count lines, so its cost does not grow with the buffer size."
  (save-excursion
    (goto-char (window-start))
    (skip-chars-forward "^\n")
    (eobp)))

(defun good-scroll--advice-line-move (line-move &rest args)
  "Call LINE-MOVE with ARGS, but avoid resetting the vscroll.
This function is used as advice to the `line-move' function."
  (if (good-scroll--point-at-top-p)
      ;; If point is at the top,
      ;; default to the old behavior of resetting the vscroll.
      ;; It makes sense to show the full top line when the point moves up.
      (apply line-move args)
    ;; Use dynamic scoping to bind function
    ;; https://endlessparentheses.com/understanding-letf-and-how-it-replaces-flet.html
    (cl-letf (((symbol-function #'set-window-vscroll) #'ignore))
      (apply line-move args))))

(defun good-scroll-up (&optional _delta)
  "Scroll up one step.
The value of DELTA is ignored and exists only for compatibility with
`mwheel-scroll-up-function'."
  (interactive)
  (good-scroll-move good-scroll-step))

(defun good-scroll-down (&optional _delta)
  "Scroll down one step.
The value of DELTA is ignored and exists only for compatibility with
`mwheel-scroll-down-function'."
  (interactive)
  (good-scroll-move (- good-scroll-step)))

(defun good-scroll-up-full-screen ()
  "Scroll up by a full screen."
  (interactive)
  (good-scroll-move (good-scroll--window-usable-height)))

(defun good-scroll-down-full-screen ()
  "Scroll down by a full screen."
  (interactive)
  (good-scroll-move (- (good-scroll--window-usable-height))))

(defun good-scroll-move (step)
  "Begin a scroll of STEP pixel lines.
A negative STEP means to scroll down. This is a helper function for
`good-scroll-up' and `good-scroll-down'."
  (unless (input-pending-p)
    (setq good-scroll-destination
          (+ step
             ;; Reset destination if scroll changed direction
             (if (> (* step good-scroll-direction) 0)
                 good-scroll-destination
               0))
          good-scroll-start-time (float-time)
          good-scroll-traveled 0
          good-scroll-direction step
          good-scroll--window (selected-window))
    (good-scroll--start-timer)))

(defun good-scroll--cached-point-top-dirty-p ()
  "Return t if the point moved or window scrolled since the last render.
Otherwise, return nil.
If the point moved or window scrolled since the last render,
this leads to `good-scroll--cached-point-top' being invalidated."
  (not (and good-scroll--prev-vscroll
            good-scroll--prev-point
            (= good-scroll--prev-point (point))
            (= good-scroll--prev-vscroll (window-vscroll nil t))
            (good-scroll--window-and-window-start-same-p))))

(defun good-scroll--render ()
  "Render an in-progress scroll.
Update the window's vscroll and position in the buffer based on the scroll
progress. This is called by the timer `good-scroll--timer' every
`good-scroll-render-rate' seconds while a scroll is in progress.
When there is nothing left to scroll, this stops the timer."
  (if (not (and (window-valid-p good-scroll--window)
                (numberp good-scroll-destination)
                (not (zerop good-scroll-destination))))
      ;; The window that received the scroll event is gone,
      ;; or there is no distance left to scroll.
      (progn
        (setq good-scroll-destination 0)
        (good-scroll--stop-timer))
    (condition-case err
        (good-scroll--render-frame)
      (error
       ;; Don't keep failing every `good-scroll-render-rate' seconds.
       (setq good-scroll-destination 0)
       (good-scroll--stop-timer)
       (signal (car err) (cdr err))))
    (when (zerop good-scroll-destination)
      (good-scroll--stop-timer))))

(defun good-scroll--render-frame ()
  "Render one frame of an in-progress scroll.
This is a helper function for `good-scroll--render'."
  (let ((inhibit-redisplay t)) ; TODO: Does this do anything?
    ;; Switch to the window that recieved the scroll event,
    ;; which might be different from the previously selected window.
    (with-selected-window good-scroll--window
      (let ((position-next-try
             (funcall good-scroll-algorithm))
            (position-next-actual))
        (cl-assert (<= (abs position-next-try)
                       (abs good-scroll-destination)))
        ;; If the animation hasn't advanced a whole pixel line since the last
        ;; frame (the start of a scroll, or the slow tail of an easing curve),
        ;; there is nothing to draw.
        ;; Skipping the frame avoids laying out lines and,
        ;; more importantly, avoids making Emacs redisplay the window
        ;; for no visible change.
        (unless (zerop position-next-try)
          (when good-scroll-inhibit-bidi-during-scroll
            (good-scroll--inhibit-bidi))
          (when (good-scroll--cached-point-top-dirty-p)
            (setq good-scroll--cached-point-top nil))
          (setq position-next-actual (good-scroll--go-to position-next-try))
          (setq good-scroll-traveled (+ good-scroll-traveled
                                        position-next-actual)
                good-scroll-destination (- good-scroll-destination
                                           position-next-actual)
                good-scroll--prev-point (point)
                good-scroll--prev-window-start (window-start)
                good-scroll--prev-vscroll (window-vscroll nil t))
          ;; If we didn't jump the position as much as we wanted,
          ;; then we must be trying to scroll past the edge of the buffer.
          ;; This interrupts the scroll, so reset the destination to zero.
          (when (/= position-next-try position-next-actual)
            (setq good-scroll-destination 0)))))))

(defun good-scroll--first-y ()
  "Return the cursor's first possible pixel y coordinate.
The return value is the number of pixels from top of window
to area below the tab and header lines, if any."
  (+ (window-tab-line-height) (window-header-line-height)))

(defun good-scroll--point-top ()
  "Return the pixel coordinate y-value of the top of the cursor.
This is the distance from the top of the usable part of the window
to the top of the cursor.
The usable part of the window is the area where the cursor is allowed to be:
below the tab and header lines."
  ;; Distance from top of usable part of window
  ;; to topmost visible part of the cursor.
  ;; The actual top of the cursor might be above this if the top of the window
  ;; overlaps the cursor.
  (let* ((p-vis-top (- (nth 1 (pos-visible-in-window-p nil nil t))
                       (good-scroll--first-y))))
    (if (zerop p-vis-top)
        ;; If the visible part of the cursor is at the top,
        ;; a nonzero vscroll can make the real top of the cursor
        ;; above the top of the usable part of the window.
        (- p-vis-top (window-vscroll nil t))
      p-vis-top)))

(defun good-scroll--move-point-up ()
  "Move the cursor up and update `good-scroll--cached-point-top' accordingly.
Return the pixel height of the line the cursor moved to,
or nil if the cursor can't move up."
  (when (= -1 (vertical-motion -1))
    (let ((height (line-pixel-height)))
      (setq good-scroll--cached-point-top
            (- good-scroll--cached-point-top height))
      height)))

(defun good-scroll--move-point-down (height &optional next-height)
  "Move the cursor down and update `good-scroll--cached-point-top' accordingly.
HEIGHT is the pixel height of the cursor's current line.
If NEXT-HEIGHT is non-nil, it is the pixel height of the line below.
Return the pixel height of the line the cursor moved to,
or nil if the cursor can't move down."
  (if (= 1 (vertical-motion 1))
      (progn
        (setq good-scroll--cached-point-top
              (+ good-scroll--cached-point-top height))
        (or next-height (line-pixel-height)))
    ;; If point is on the last line,
    ;; `vertical-motion' moves it to the end of the line.
    ;; This causes a jitter, so avoid it.
    (beginning-of-line)
    nil))

(defun good-scroll--window-usable-height ()
  "Return the usable height of the selected window.
Return the pixel height of the area of the selected window
that the cursor is allowed to be inside.
This is from the bottom of the header line to the top of the mode line."
  (let* ((w-edges (window-inside-pixel-edges))
         ;; Number of pixels from top of frame to top of selected window
         ;; The top of the window is considered the top of the tab line,
         ;; if it exists.
         (w-top (- (nth 1 w-edges) (window-header-line-height)))
         ;; Number of pixels from top of frame to bottom of selected window
         ;; The bottom of the window is considered the top of the mode line.
         (w-bottom (+ (nth 3 w-edges) (window-tab-line-height))))
    (- w-bottom w-top (good-scroll--first-y))))

(defun good-scroll--next-line-pixel-height ()
  "Return the pixel height of the line below the cursor."
  (save-excursion
    (vertical-motion 1)
    (line-pixel-height)))

(defun good-scroll--move-point-out-of-way (delta)
  "Move the cursor to prepare for a scroll of DELTA pixel lines.
Emacs doesn't allow the cursor to be outside the window,
so move it as little as possible to avoid this.
Return t if the cursor moved, nil otherwise.
The cursor moves one line at a time until it no longer needs to move.
The pixel geometry of the cursor's line is tracked across those moves,
so each line the cursor passes costs one layout of that line
instead of several."
  (let* ((p-start (point)) ; Cursor position
         (w-usable-height (good-scroll--window-usable-height))
         ;; Number of pixels from top of window to top of cursor
         ;; This can be negative if the top of the window overlaps the cursor.
         (p-top (setq good-scroll--cached-point-top
                      (or good-scroll--cached-point-top
                          (good-scroll--point-top))))
         ;; Pixel height of cursor
         (p-height (line-pixel-height)))
    (while
        (let* (
               ;; Number of pixels from top of window to bottom of cursor
               (p-bottom (+ p-top p-height))
               ;; Number of pixels from top of window to top of cursor,
               ;; after scrolling `delta' pixel lines.
               (p-next-top (- p-top delta))
               ;; Number of pixels from top of window to bottom of cursor,
               ;; after scrolling `delta' pixel lines.
               (p-next-bottom (- p-bottom delta))
               ;; Is the cursor going to overlap the top of the window?
               (p-overlaps-top (< p-next-top 0 p-next-bottom))
               ;; Pixel height of line below cursor.
               ;; This is expensive, so it is only computed when needed.
               (nl-height nil)
               ;; Where to move the cursor, if anywhere
               (direction
                (progn
                  (good-scroll--log "R1"
                                    good-scroll--cached-point-top
                                    (good-scroll--point-top))
                  (good-scroll--slow-assert (= good-scroll--cached-point-top
                                               (good-scroll--point-top)))
                  (cond
                   ;; The scroll is going to make the bottom of the cursor
                   ;; go below the bottom of the window.
                   ;; Move it up to avoid this.
                   ;; The exception is when the cursor height
                   ;; is greater than the window height.
                   ((and (> p-next-bottom w-usable-height)
                         (> w-usable-height p-height))
                    (good-scroll--log "move point out of way case 1")
                    'up)
                   ;; The scroll is going to make the bottom of the cursor go
                   ;; above the window, which would make the cursor go
                   ;; completely offscreen.
                   ;; Move the cursor down to avoid this.
                   ((<= p-next-bottom 0)
                    (good-scroll--log "move point out of way case 2")
                    'down)
                   ;; The scroll is going to make the cursor overlap the top
                   ;; of the window.
                   ;; Move the cursor down to avoid this if there's room.
                   ((and p-overlaps-top
                         ;; Number of pixels from top of window to bottom of
                         ;; line below cursor, after scrolling `delta'
                         ;; pixel lines.
                         (<= (- (+ p-bottom
                                   (setq nl-height
                                         (good-scroll--next-line-pixel-height)))
                                delta)
                             w-usable-height))
                    (good-scroll--log "move point out of way case 3")
                    'down)
                   ;; The cursor is not going to overlap the top of the window
                   ;; and the cursor height is greater than the window height.
                   ;; Move the point up, because we want to maintain the
                   ;; property that when the cursor height exceeds the window
                   ;; height, there shouldn't be any space between the cursor
                   ;; and the top of the window.
                   ;; Breaking this property is inconsistent with case 1
                   ;; and can prevent scrolling down.
                   ((and (not p-overlaps-top) (> p-height w-usable-height))
                    (good-scroll--log "move point out of way case 4")
                    'up)))))
          ;; Move the cursor and find the geometry of its new line.
          ;; If the cursor couldn't move, then it's done moving.
          (let ((new-height (pcase direction
                              ('up (good-scroll--move-point-up))
                              ('down (good-scroll--move-point-down
                                      p-height nl-height)))))
            (when new-height
              (setq p-top good-scroll--cached-point-top
                    p-height new-height)))))
    ;; Return if the cursor position changed
    (/= p-start (point))))

(defun good-scroll--go-to (target)
  "Jump the window by TARGET pixel lines.
Update the window's vscroll and position in the buffer to instantly scroll to
TARGET, where TARGET is the index from the top of the window in pixel lines.
TARGET can be negative.
Return the number of pixels (possibly negative) scrolled successfully."
  (good-scroll--move-point-out-of-way target)
  (good-scroll--log "cached-point-top assertion 2"
                    target
                    good-scroll--cached-point-top
                    (good-scroll--point-top))
  (good-scroll--slow-assert (= good-scroll--cached-point-top
                               (good-scroll--point-top)))
  (let ((remaining target))
    (while
        (let* (
               ;; Number of pixels scrolled past the top of the first line.
               (vscroll (window-vscroll nil t))
               (prev-remaining remaining))
          (setq remaining
                (cond
                 ((> remaining 0)
                  (let* (
                         ;; Pixel height of the first line.
                         ;; Only scrolling up needs this, and
                         ;; it requires laying out the line.
                         (line-height (save-excursion
                                        (goto-char (window-start))
                                        (line-pixel-height)))
                         ;; Remaining number of pixels in the first line
                         (line-remaining (- line-height vscroll)))
                    (good-scroll--go-to-up remaining
                                           vscroll
                                           line-height
                                           line-remaining)))
                 ((< remaining 0) (good-scroll--go-to-down remaining vscroll))
                 (t remaining)))
          (/= remaining prev-remaining)))
    (let ((traveled (- target remaining)))
      (setq good-scroll--cached-point-top
            (- good-scroll--cached-point-top traveled))
      (good-scroll--log "R3"
                        traveled
                        target
                        remaining
                        good-scroll--cached-point-top
                        (good-scroll--point-top))
      (good-scroll--slow-assert (= good-scroll--cached-point-top
                                   (good-scroll--point-top)))
      traveled)))

(defun good-scroll--go-to-up (pos vscroll line-height rem)
  "Partially jump the window up by POS pixel lines.
Return the remaining number of pixel lines to scroll.

The parameter VSCROLL is the selected window's vscroll,
LINE-HEIGHT is the height in pixels of the first line in the selected window,
and REM is the number of pixel lines from the vscroll to the end of the first
line in the selected window."
  (good-scroll--log "good-scroll--go-to-up"
                    pos
                    vscroll
                    line-height
                    rem
                    (window-start)
                    good-scroll--cached-point-top
                    (good-scroll--point-top))
  (if (< (+ vscroll pos) line-height)
      ;; Done scrolling except for a fraction of a line.
      ;; Scroll a fraction of a line and terminate.
      (good-scroll--go-to-up-partial pos vscroll)
    ;; Scroll a full line
    (good-scroll--go-to-up-full pos rem)))

(defun good-scroll--go-to-up-partial (pos vscroll)
  "Increase the current window's vscroll by POS pixels.
Return zero. Assume VSCROLL + POS is less than the pixel height of the current
line and the current window's vscroll is VSCROLL."
  (good-scroll--log "good-scroll--go-to-up-partial before"
                    pos
                    vscroll
                    good-scroll--cached-point-top
                    (good-scroll--point-top))
  (set-window-vscroll nil (+ vscroll pos) t)
  (good-scroll--log "good-scroll--go-to-up-partial after"
                    (good-scroll--point-top))
  0)


(defun good-scroll--go-to-up-full (pos rem)
  "Scroll the screen up by a full line.
Return the next target scroll position. Assume POS > REM, where REM is the
remaining amount of pixels from the top of the screen to the end of the top
line."
  (good-scroll--log "good-scroll--go-to-up-full"
                    pos
                    rem
                    (window-start)
                    good-scroll--cached-point-top
                    (good-scroll--point-top))
  ;; Are we at the end of the buffer?
  (if (good-scroll--window-start-on-last-line-p)
      ;; We are!
      ;; Print a message and terminate.
      (progn
        (message (get #'end-of-buffer 'error-message))
        pos)
    ;; We aren't.
    ;; Actually scroll one line
    (set-window-vscroll nil 0 t)
    (set-window-start nil (save-excursion
                            (goto-char (window-start))
                            (vertical-motion 1)
                            (point))
                      t)
    (good-scroll--log "good-scroll--go-to-up-full after"
                      (window-start)
                      good-scroll--cached-point-top
                      (good-scroll--point-top))
    (- pos rem)))

(defun good-scroll--go-to-down (pos vscroll)
  "Partially jump the window down by POS pixel lines.
Return the remaining number of pixel lines to scroll. The parameter VSCROLL is
the selected window's vscroll."
  (good-scroll--log "good-scroll--go-to-down"
                    pos
                    vscroll
                    good-scroll--cached-point-top
                    (good-scroll--point-top))
  (if (<= (- pos) vscroll)
      ;; Done scrolling except for a fraction of a line.
      ;; Scroll a fraction of a line and terminate.
      (good-scroll--go-to-down-partial pos vscroll)
    ;; Scroll a full line
    (good-scroll--go-to-down-full pos vscroll)))

(defun good-scroll--go-to-down-partial (pos vscroll)
  "Change the current window's vscroll by POS pixels.
Return zero. Assume -POS <= VSCROLL."
  (good-scroll--log "good-scroll--go-to-down-partial before"
                    pos
                    vscroll
                    good-scroll--cached-point-top
                    (good-scroll--point-top))
  (set-window-vscroll nil (+ vscroll pos) t)
  (good-scroll--log "good-scroll--go-to-down-partial after"
                    (good-scroll--point-top))
  0)

(defun good-scroll--go-to-down-full (pos vscroll)
  "Scroll the screen down by a full line.
Return the next target scroll position. Assume POS > VSCROLL."
  (good-scroll--log "good-scroll--go-to-down-full before"
                    pos
                    vscroll
                    good-scroll--cached-point-top
                    (good-scroll--point-top))
  (set-window-vscroll nil 0 t)
  ;; Are we at the beginning of the buffer?
  (if (good-scroll--window-start-on-first-line-p)
      ;; We are!
      ;; Print a message and terminate.
      (progn
        (message (get #'beginning-of-buffer 'error-message))
        (+ pos vscroll))
    (good-scroll--log "good-scroll--go-to-down-full mid"
                      (good-scroll--point-top))
    ;; We aren't.
    ;; Actually scroll one line
    (set-window-start nil (save-excursion
                            (goto-char (window-start))
                            (vertical-motion -1)
                            (point))
                      t)
    (good-scroll--log "good-scroll--go-to-down-full after"
                      (good-scroll--point-top))
    (+ pos vscroll
       (save-excursion
         (goto-char (window-start))
         (line-pixel-height)))))

(provide 'good-scroll)

;;; good-scroll.el ends here
