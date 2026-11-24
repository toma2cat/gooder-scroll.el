;;; good-scroll-test.el --- Unit testing for good-scroll -*- lexical-binding: t; -*-

;; Copyright (C) 2021 Benjamin Levy - MIT/X11 License
;; Author: Benjamin Levy <blevy@protonmail.com>
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

;; This library contains ERT unit tests for good-scroll.
;; They can be run with `ert-run-tests-interactively'.

;;; Code:

(require 'good-scroll)

(require 'ert)



;;; good-scroll-linear.el

(ert-deftest good-scroll-test-linear ()
  (with-temp-buffer
    (cl-flet ((test-case
               (traveled destination zero half one)
               (set (make-local-variable 'good-scroll-duration) 1.0)
               (set (make-local-variable 'good-scroll-traveled) traveled)
               (set (make-local-variable 'good-scroll-destination) destination)
               (set (make-local-variable 'good-scroll-start-time) (float-time))
               (should (= (good-scroll-linear) zero))
               (set (make-local-variable 'good-scroll-start-time)
                    (- (float-time) 0.5))
               (should (= (good-scroll-linear) half))
               (set (make-local-variable 'good-scroll-start-time)
                    (- (float-time) 1.0))
               (should (= (good-scroll-linear) one))))
      (test-case 0 10 0 5 10)
      (test-case 0 -10 0 -5 -10)
      (test-case 10 20 -10 5 20)
      (test-case -10 20 10 15 20)
      (test-case 10 -20 -10 -15 -20))))



;;; good-scroll-bezier.el

(ert-deftest good-scroll-test-bezier-t-given-x ()
  (with-temp-buffer
    (cl-flet ((test-case
               (x x1 x2)
               (let* ((tt (good-scroll-bezier--t-given-x x x1 x2))
                      (x- (good-scroll-bezier--calc tt x1 x2)))
                 (should (good-scroll-bezier--approx-eq-p x x-)))))
      (test-case 0.0 0.0 0.0)
      (test-case 0.5 0.0 0.0)
      (test-case 0.0 0.1 3.1)
      (test-case 1.0 2.0 3.0)
      (test-case 0.0 -0.1 3.1)
      (test-case 0.0 0.1 -3.1)
      (test-case 1.0 -2.0 -3.0)
      (test-case 1.0 2.0 -3.0)
      (test-case 0.5 2.0 3.0)
      (test-case 1.0 -2.0 3.0))))

(ert-deftest good-scroll-test-bezier-maintain-velocity ()
  (with-temp-buffer
    (cl-flet ((test-case
               (velocity duration traveled destination epsilon half)
               (set (make-local-variable 'good-scroll-duration) duration)
               (set (make-local-variable 'good-scroll-traveled) traveled)
               (set (make-local-variable 'good-scroll-destination) destination)
               (good-scroll-bezier--set-points velocity)
               (should (good-scroll-bezier--approx-eq-p
                        (good-scroll-bezier--velocity-at 0.0) velocity epsilon))
               (should (good-scroll-bezier--approx-eq-p
                        (good-scroll-bezier--velocity-at 0.5) half epsilon))
               (should (good-scroll-bezier--approx-eq-p
                        (good-scroll-bezier--velocity-at 1.0) 0.0 epsilon))))
      (test-case 0.0 0.1 0 1 0.01 14.2934)
      (test-case 0.0 1.0 0 1 0.01 1.4293)
      (test-case 0.0 10.0 0 1 0.01 0.1429)
      (test-case 1.0 0.1 0 1 0.01 14.0608)
      (test-case 1.0 1.0 0 1 0.01 1.1677)
      (test-case 1.0 10.0 0 1 0.1 0.1406)
      (test-case 1234.56 0.1 50 20 1000.0 1.0)
      (test-case 1234.56 1.0 50 20 1000.0 1.0)
      (test-case 1234.56 10.0 50 20 1000.0 1.0))))



;;; good-scroll.el

(defmacro good-scroll-test--with-window-buffer (&rest body)
  "Run BODY in a temporary buffer displayed in the selected window."
  (declare (indent 0))
  `(let ((window (selected-window))
         (old-buffer (window-buffer)))
     (unwind-protect
         (with-temp-buffer
           (set-window-buffer window (current-buffer))
           ,@body)
       (set-window-buffer window old-buffer))))

(ert-deftest good-scroll-test-timer-lifecycle ()
  (let ((good-scroll--timer nil)
        (good-scroll--window nil)
        (good-scroll-destination 0))
    (unwind-protect
        (progn
          (good-scroll--start-timer)
          (let ((timer good-scroll--timer))
            (should (memq timer timer-list))
            ;; Starting again must not create a second timer
            (good-scroll--start-timer)
            (should (eq timer good-scroll--timer))
            (should (= 1 (cl-count timer timer-list))))
          ;; With no scrolling to do, rendering stops the timer
          (let ((timer good-scroll--timer))
            (good-scroll--render)
            (should (null good-scroll--timer))
            (should-not (memq timer timer-list)))
          ;; Stopping when already stopped is harmless
          (good-scroll--stop-timer)
          (should (null good-scroll--timer)))
      (good-scroll--stop-timer))))

(ert-deftest good-scroll-test-inhibit-bidi-not-local ()
  (with-temp-buffer
    (let ((good-scroll--bidi-saved nil))
      (should-not (local-variable-p 'bidi-display-reordering))
      (good-scroll--inhibit-bidi)
      (should (null bidi-display-reordering))
      ;; Calling again for the same buffer changes nothing
      (good-scroll--inhibit-bidi)
      (good-scroll--restore-bidi)
      (should (eq t bidi-display-reordering))
      (should-not (local-variable-p 'bidi-display-reordering))
      (should (null good-scroll--bidi-saved)))))

(ert-deftest good-scroll-test-inhibit-bidi-local ()
  (dolist (value '(t nil))
    (with-temp-buffer
      (let ((good-scroll--bidi-saved nil))
        (setq-local bidi-display-reordering value)
        (good-scroll--inhibit-bidi)
        (should (null bidi-display-reordering))
        (good-scroll--restore-bidi)
        (should (local-variable-p 'bidi-display-reordering))
        (should (eq value bidi-display-reordering))))))

(ert-deftest good-scroll-test-inhibit-bidi-buffer-switch-and-kill ()
  (let ((good-scroll--bidi-saved nil)
        (a (generate-new-buffer " *good-scroll-test-a*"))
        (b (generate-new-buffer " *good-scroll-test-b*")))
    (unwind-protect
        (progn
          (with-current-buffer a (good-scroll--inhibit-bidi))
          ;; Scrolling continues in another buffer: the first is restored
          (with-current-buffer b (good-scroll--inhibit-bidi))
          (with-current-buffer a
            (should (eq t bidi-display-reordering)))
          (with-current-buffer b
            (should (null bidi-display-reordering)))
          ;; Restoring after the buffer was killed must not fail
          (kill-buffer b)
          (good-scroll--restore-bidi)
          (should (null good-scroll--bidi-saved)))
      (kill-buffer a)
      (when (buffer-live-p b)
        (kill-buffer b)))))

(ert-deftest good-scroll-test-stop-timer-restores-bidi ()
  (with-temp-buffer
    (let ((good-scroll--bidi-saved nil)
          (good-scroll--timer nil))
      (good-scroll--inhibit-bidi)
      (good-scroll--stop-timer)
      (should (eq t bidi-display-reordering)))))

(ert-deftest good-scroll-test-point-at-top-p ()
  ;; Compare against the straightforward line-counting definition
  (dolist (text '("one\ntwo\nthree\nfour\n\n\nsix no newline at end"
                  "single line"
                  "\n\n\n"
                  ""))
    (dolist (narrow '(nil t))
      (good-scroll-test--with-window-buffer
        (insert text)
        (when (and narrow (> (point-max) 3))
          (narrow-to-region 2 (1- (point-max))))
        (let ((lo (point-min))
              (hi (point-max)))
          (cl-loop
           for start from lo to hi
           do (set-window-start nil start t)
              (cl-loop
               for pt from lo to hi
               do (goto-char pt)
                  (should
                   (eq (and (good-scroll--point-at-top-p) t)
                       (save-restriction
                         (widen)
                         (<= (line-number-at-pos pt t)
                             (1+ (line-number-at-pos (window-start) t)))))))))))))

(ert-deftest good-scroll-test-window-start-on-edge-line-p ()
  (dolist (text '("one\ntwo\nthree\nfour\n" "one\ntwo\nthree" "x" "\n\n" ""))
    (dolist (narrow '(nil t))
      (good-scroll-test--with-window-buffer
        (insert text)
        (when (and narrow (> (point-max) 3))
          (narrow-to-region 2 (1- (point-max))))
        (cl-loop
         for start from (point-min) to (point-max)
         do (set-window-start nil start t)
            (should (eq (and (good-scroll--window-start-on-first-line-p) t)
                        (= (line-number-at-pos (point-min))
                           (line-number-at-pos (window-start)))))
            (should (eq (and (good-scroll--window-start-on-last-line-p) t)
                        (= (line-number-at-pos (point-max))
                           (line-number-at-pos (window-start))))))))))



(provide 'good-scroll-test)

;;; good-scroll-test.el ends here
