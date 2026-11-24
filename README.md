[![MELPA](https://melpa.org/packages/good-scroll-badge.svg)](https://melpa.org/#/good-scroll)
[![Check](https://github.com/io12/good-scroll.el/actions/workflows/check.yml/badge.svg)](https://github.com/io12/good-scroll.el/actions/workflows/check.yml)

# `good-scroll.el`

Attempt at good pixel-based smooth scrolling in Emacs

## About

This package implements smooth scrolling by pixel lines.
It attempts to improve upon `pixel-scroll-mode` by adding variable speed.

![Demo](./demo.gif)

## Setup

Install and load the package.
Then, enable `good-scroll-mode`.
For example, you can add the following snippet to your config.

```lisp
(good-scroll-mode 1)
```

### Key bindings

If you want to bind the <kbd>Page Up</kbd> and <kbd>Page Down</kbd> keys,
you can also add the following:

```lisp
(global-set-key [next] #'good-scroll-up-full-screen)
(global-set-key [prior] #'good-scroll-down-full-screen)
```

## FAQ

### How does this work?

Instead of scroll events directly scrolling the screen,
they update a destination variable.
A timer that runs every `good-scroll-render-rate` seconds
while a scroll is in progress
calculates the expected position and actually scrolls the window to it.
To make the window scrolled partially through a line,
`good-scroll` updates the window's
[_vscroll_ (vertical scroll)](https://www.gnu.org/software/emacs/manual/html_node/elisp/Vertical-Scrolling.html)
position.

### Why is performance sometimes bad?

Scrolling sometimes pauses or stutters.
It's unclear _exactly_ why,
but one factor is that Emacs lacks animation support.
Emacs has timers for updating the screen contents,
which is enough for playing simple animated GIF files,
but not enough for video playback or frame-perfect smooth scrolling.

### How can I reduce CPU usage while scrolling?

The render timer only runs while a scroll is in progress,
so an idle Emacs uses no CPU for `good-scroll`.
While scrolling, each animation frame makes Emacs redraw the whole window,
so CPU usage is roughly proportional to the number of frames per second.
There are two ways to reduce it:

- Increase `good-scroll-render-rate`.
  For example, `0.033` is about 30 frames per second
  and uses noticeably less CPU than the default `0.02`,
  at the cost of a less smooth animation.
- Set `good-scroll-inhibit-bidi-during-scroll` to `t`.
  This turns off bidirectional text reordering while the animation runs,
  which made scrolling use around 20% less CPU in our measurements.
  Left-to-right text looks the same,
  but text with right-to-left characters is shown in logical order
  until the animation ends.

### How does this compare to other scrolling packages?

Other modifications, like
[`smooth-scrolling`](https://github.com/aspiers/smooth-scrolling),
[`smooth-scroll`](https://github.com/k-talo/smooth-scroll.el),
[`sublimity-scroll`](https://github.com/zk-phi/sublimity),
and [`inertial-scroll`](https://github.com/kiwanami/emacs-inertial-scroll)
also aim to improve scrolling in Emacs,
but none of them involve scrolling by pixel lines, only by text lines.
The built-in
[`pixel-scroll`](https://git.savannah.gnu.org/cgit/emacs.git/tree/lisp/pixel-scroll.el)
_does_ implement pixel line scrolling,
but, unlike `good-scroll`, does not support dynamic scrolling velocity.

### Why is this file written in Markdown and not Org?

Apparently, GitHub does not yet support rendering
Org links with formatting inside of them.

https://github.com/novoid/github-orgmode-tests/issues/3
