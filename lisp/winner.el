;;; winner.el --- Restore old window configurations  -*- lexical-binding: t -*-

;; Copyright (C) 1997-1998, 2001-2025 Free Software Foundation, Inc.

;; Author: Ivar Rummelhoff <ivarru@math.uio.no>
;; Created: 27 Feb 1997
;; Keywords: convenience frames

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Winner mode is a global minor mode that records the changes in the
;; window configuration (in other words, how the frames are partitioned
;; into windows), so that the changes can be "undone" using the command
;; `winner-undo'.  By default, it is bound to the key sequence `C-c
;; <left>'.  If you change your mind (while undoing), you can press
;; `C-c <right>' (`winner-redo').

;;; Code:

(eval-when-compile (require 'cl-lib))
(require 'ring)

(defun winner-active-region ()
  (declare (gv-setter (lambda (store)
                        `(if ,store (activate-mark) (deactivate-mark)))))
  (region-active-p))

(defgroup winner nil
  "Restoring window configurations."
  :group 'windows)

(defun winner--set-dont-bind-my-keys (symbol value)
  (defvar winner-mode-map)
  (when (boundp 'winner-mode-map)
    (if value
        (progn (keymap-unset winner-mode-map "C-c <left>")
               (keymap-unset winner-mode-map "C-c <right>"))
      ;; Default bindings.
      (keymap-set winner-mode-map "C-c <left>" #'winner-undo)
      (keymap-set winner-mode-map "C-c <right>" #'winner-redo)))
  (set-default symbol value))

(defcustom winner-dont-bind-my-keys nil
  "Non-nil means do not bind default keys in Winner mode."
  :type 'boolean
  :set #'winner--set-dont-bind-my-keys)

(defcustom winner-ring-size 200
  "Maximum number of stored window configurations per frame."
  :type 'natnum)

(defcustom winner-boring-buffers '("*Completions*")
  "List of buffer names whose windows `winner-undo' will not restore.
You may want to include buffer names such as *Help*, *Apropos*,
*Buffer List*, *info* and *Compile-Log*."
  :type '(repeat string))

(defcustom winner-boring-buffers-regexp nil
  "`winner-undo' will not restore windows with buffers matching this regexp."
  :type '(choice (regexp :tag "Regexp")
                 (const :tag "Not Set" nil))
  :version "27.1")


;;;; Saving old configurations (internal variables and subroutines)


;;; Current configuration

;; List the windows according to their edges.
(defun winner-sorted-window-list ()
  (sort (window-list nil 0)
        (lambda (x y)
          (cl-loop for a in (window-edges x)
                   for b in (window-edges y)
                   while (= a b)
                   finally return (< a b)))))

(defun winner-win-data ()
  ;; Essential properties of the windows in the selected frame.
  (cl-loop for win in (winner-sorted-window-list)
           collect (cons (window-edges win) (window-buffer win))))

;; This variable is updated with the current window configuration
;; every time it changes.
(defvar winner-currents nil)

;; The current configuration (+ the buffers involved).
(defsubst winner-conf ()
  (cons (current-window-configuration)
        (winner-win-data)))


;; Save current configuration.
;; (Called below by `winner-save-old-configurations').
(defun winner-remember ()
  (setf (alist-get (selected-frame) winner-currents) (winner-conf)))

;; Consult `winner-currents'.
(defun winner-configuration (&optional frame)
  (or (cdr (assq (or frame (selected-frame)) winner-currents))
      (with-selected-frame frame
	(winner-conf))))



;;; Saved configurations

;; This variable contains the window configuration rings.
;; The key in this alist is the frame.
(defvar winner-ring-alist nil)

;; Find the right ring.  If it does not exist, create one.
(defsubst winner-ring (frame)
  (or (cdr (assq frame winner-ring-alist))
      (let ((ring (make-ring winner-ring-size)))
        (ring-insert ring (winner-configuration frame))
        (push (cons frame ring) winner-ring-alist)
        ring)))


;; If the same command is called several times in a row,
;; we only save one window configuration.
(defvar winner-last-command nil)

;; Frames affected by the previous command.
(defvar winner-last-frames nil)


(defsubst winner-equal (a b)
  "Return t if two Winner configurations (as produced by `winner-conf') are equal."
  (equal (cdr a) (cdr b)))


;; Save the current window configuration, if it has changed.
;; If so return frame, otherwise return nil.
(defun winner-insert-if-new (frame)
  (unless (or (memq frame winner-last-frames)
	      (eq this-command 'winner-redo))
    (let ((conf (winner-configuration frame))
	  (ring (winner-ring frame)))
      (when (and (not (ring-empty-p ring))
		 (winner-equal conf (ring-ref ring 0)))
        ;; When the previous configuration was very similar,
        ;; keep only the latest.
	(ring-remove ring 0))
      (ring-insert ring conf)
      (push frame winner-last-frames)
      frame)))



;;; Hooks

;; Frames affected by the current command.
(defvar winner-modified-list nil)

;; Called whenever the window configuration changes
;; (a `window-configuration-change-hook').
(defun winner-change-fun ()

  ;; Cull dead frames.
  (setq winner-modified-list
        (cl-loop for frame in winner-modified-list
             if (frame-live-p frame) collect frame))

  (unless (or (memq (selected-frame) winner-modified-list)
              (/= 0 (minibuffer-depth)))
    (push (selected-frame) winner-modified-list)))

;; Used as `post-command-hook'.
(defun winner-save-old-configurations ()
  (when (zerop (minibuffer-depth))
    (unless (eq this-command winner-last-command)
      (setq winner-last-frames nil)
      (setq winner-last-command this-command))
    (dolist (frame winner-modified-list)
      (if (frame-live-p frame)
          (winner-insert-if-new frame)))
    (setq winner-modified-list nil)
    (winner-remember)))

;; A `minibuffer-setup-hook'.
(defun winner-save-unconditionally ()
  (unless (eq this-command winner-last-command)
    (setq winner-last-frames nil)
    (setq winner-last-command this-command))
  (winner-insert-if-new (selected-frame))
  (winner-remember))

;; Called by `winner-undo' before "undoing".
(defun winner-save-conditionally ()
  (when (zerop (minibuffer-depth))
    (winner-save-unconditionally)))




;;;; Restoring configurations

;; Works almost as `set-window-configuration',
;; but does not change the contents or the size of the minibuffer,
;; and tries to preserve the selected window.
(defun winner-set-conf (winconf)
  (let* ((miniwin  (minibuffer-window))
         (chosen   (selected-window))
         (minisize (window-height miniwin)))
    (cl-letf (((window-buffer miniwin))
              ((window-point  miniwin)))
      (set-window-configuration winconf))
    (cond
     ((window-live-p chosen) (select-window chosen))
     ((window-minibuffer-p) (other-window 1)))
    (when (/= minisize (window-height miniwin))
      (with-selected-window miniwin
        (enlarge-window (- minisize (window-height)))))))


(defvar winner-point-alist nil)
;; `set-window-configuration' restores old points and marks.  This is
;; not what we want, so we make a list of the "real" (i.e. new) points
;; and marks before undoing window configurations.
;;
;; Format of entries: (buffer (mark . mark-active) (window . point) ..)

(defun winner-make-point-alist ()
  (save-current-buffer
    (cl-loop with alist
             for win in (window-list nil 0)
             for entry =
             (or (assq (window-buffer win) alist)
                 (car (push (list (set-buffer (window-buffer win))
                                  (cons (mark t) (winner-active-region)))
                            alist)))
             do (push (cons win (window-point win))
                      (cddr entry))
             finally return alist)))

(defun winner-get-point (buf win)
  ;; Consult (and possibly extend) `winner-point-alist'.
  ;; Returns nil if buf no longer exists.
  (when (buffer-name buf)
    (let ((entry (assq buf winner-point-alist)))
      (cond
       (entry
	(or (cdr (assq win (cddr entry)))
	    (cdr (assq nil (cddr entry)))
	    (with-current-buffer buf
	      (push (cons nil (point)) (cddr entry))
	      (point))))
       (t (with-current-buffer buf
	    (push (list buf
			(cons (mark t) (winner-active-region))
			(cons nil (point)))
		  winner-point-alist)
	    (point)))))))


;; Make sure point does not end up in the minibuffer and delete
;; windows displaying dead or boring buffers
;; (cf. `winner-boring-buffers') and `winner-boring-buffers-regexp'.
;; Return nil if all the windows should be deleted.  Preserve correct
;; points and marks.
(defun winner-set (conf)
  ;; For the format of `conf', see `winner-conf'.
  (let* ((buffers nil)
	 (alive
          ;; Possibly update `winner-point-alist'
          (cl-loop for buf in (mapcar #'cdr (cdr conf))
                   for pos = (winner-get-point buf nil)
                   if (and pos (not (memq buf buffers)))
                   do (push buf buffers)
                   collect pos)))
    (winner-set-conf (car conf))
    (let (xwins)                        ; to be deleted

      ;; Restore points
      (dolist (win (winner-sorted-window-list))
        (unless (and (pop alive)
                     (setf (window-point win)
                           (winner-get-point (window-buffer win) win))
		     (not (or (member (buffer-name (window-buffer win))
				      winner-boring-buffers)
			      (and winner-boring-buffers-regexp
				   (string-match
				    winner-boring-buffers-regexp
				    (buffer-name (window-buffer win)))))))
          (push win xwins)))            ; delete this window

      ;; Restore marks
      ;; `winner-undo' shouldn't update the selection (Bug#28631) when
      ;; select-enable-primary is non-nil.
      (unless select-enable-primary
        (save-current-buffer
	  (cl-loop for buf in buffers
                   for entry = (cadr (assq buf winner-point-alist))
                   do (progn (set-buffer buf)
                             (set-mark (car entry))
                             (setf (winner-active-region) (cdr entry))))))
      ;; Delete windows, whose buffers are dead or boring.
      ;; Return t if this is still a possible configuration.
      (or (null xwins)
	  (progn
            (mapc #'delete-window (cdr xwins)) ; delete all but one
	    (unless (one-window-p t)
	      (delete-window (car xwins))
	      t))))))



;;;; Winner mode  (a minor mode)

(defcustom winner-mode-hook nil
  "Functions to run whenever Winner mode is turned on or off."
  :type 'hook)

(defcustom winner-mode-off-hook nil
  "Functions to run whenever Winner mode is turned off."
  :type 'hook)

(defvar-keymap winner-mode-map
  :doc "Keymap for Winner mode.")
(setopt winner-dont-bind-my-keys winner-dont-bind-my-keys)

(defvar-keymap winner-repeat-map
  :doc "Keymap to repeat winner key sequences.  Used in `repeat-mode'."
  :repeat t
  "<left>"  #'winner-undo
  "<right>" #'winner-redo)


;;;###autoload
(define-minor-mode winner-mode
  "Toggle Winner mode on or off.

Winner mode is a global minor mode that records the changes in
the window configuration (i.e. how the frames are partitioned
into windows) so that the changes can be \"undone\" using the
command `winner-undo'.  By default this one is bound to the key
sequence \\`C-c <left>'.  If you change your mind (while undoing),
you can press \\`C-c <right>' (calling `winner-redo').

If you use `tab-bar-mode', consider using `tab-bar-history-mode', as
`winner-mode' is unaware of tab switching, and might turn the window
configuration of the current tab to another's (old) window
configuration.  `tab-bar-history-mode' provides tab-specific window
configuration history avoiding this problem."
  :global t
  (if winner-mode
      (progn
        (add-hook 'window-configuration-change-hook 'winner-change-fun)
        (add-hook 'post-command-hook 'winner-save-old-configurations)
        (add-hook 'minibuffer-setup-hook 'winner-save-unconditionally)
        (setq winner-modified-list (frame-list))
        (winner-save-old-configurations))
    (remove-hook 'window-configuration-change-hook 'winner-change-fun)
    (remove-hook 'post-command-hook 'winner-save-old-configurations)
    (remove-hook 'minibuffer-setup-hook 'winner-save-unconditionally)))

;; Inspired by undo (simple.el)

(defvar winner-undo-frame nil)

(defvar winner-pending-undo-ring nil
  "The ring currently used by `winner-undo'.")
(defvar winner-undo-counter nil)
(defvar winner-undone-data  nil) ; There confs have been passed.

(defun winner-undo ()
  "Switch back to an earlier window configuration saved by Winner mode.
In other words, \"undo\" changes in window configuration."
  (interactive)
  (cond
   ((not winner-mode) (error "Winner mode is turned off"))
   (t (unless (and (eq last-command 'winner-undo)
 		   (eq winner-undo-frame (selected-frame)))
	(winner-save-conditionally)     ; current configuration->stack
 	(setq winner-undo-frame (selected-frame))
 	(setq winner-point-alist (winner-make-point-alist))
 	(setq winner-pending-undo-ring (winner-ring (selected-frame)))
 	(setq winner-undo-counter 0)
 	(setq winner-undone-data (list (winner-win-data))))
      (incf winner-undo-counter)	; starting at 1
      (when (and (winner-undo-this)
 		 (not (window-minibuffer-p)))
 	(message "Winner undo (%d / %d)"
 		 winner-undo-counter
 		 (1- (ring-length winner-pending-undo-ring)))))))




(defun winner-undo-this ()		; The heart of winner undo.
  (cl-loop
   (cond
    ((>= winner-undo-counter (ring-length winner-pending-undo-ring))
     (message "No further window configuration undo information")
     (cl-return nil))

    ((and				; If possible configuration
      (winner-set (ring-ref winner-pending-undo-ring
 			    winner-undo-counter))
                                        ; .. and new configuration
      (let ((data (winner-win-data)))
 	(and (not (member data winner-undone-data))
 	     (push data winner-undone-data))))
     (cl-return t))			; .. then everything is fine.
    (t ;; Otherwise, discharge it (and try the next one).
     (ring-remove winner-pending-undo-ring winner-undo-counter)))))


(defun winner-redo ()			; If you change your mind.
  "Restore a more recent window configuration saved by Winner mode."
  (interactive)
  (cond
   ((eq last-command 'winner-undo)
    (winner-set
     (if (zerop (minibuffer-depth))
         (ring-remove winner-pending-undo-ring 0)
       (ring-ref winner-pending-undo-ring 0)))
    (unless (eq (selected-window) (minibuffer-window))
      (message "Winner undid undo")))
   (t (user-error "Previous command was not a `winner-undo'"))))

(provide 'winner)
;;; winner.el ends here
