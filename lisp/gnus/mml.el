;;; mml.el --- A package for parsing and validating MML documents  -*- lexical-binding: t; -*-

;; Copyright (C) 1998-2025 Free Software Foundation, Inc.

;; Author: Lars Magne Ingebrigtsen <larsi@gnus.org>
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

;;; Code:

(require 'mm-util)
(require 'mm-bodies)
(require 'mm-encode)
(require 'mm-decode)
(require 'mml-sec)
(eval-when-compile (require 'cl-lib))
(eval-when-compile (require 'url))
(eval-when-compile (require 'gnus-util))

(autoload 'message-make-message-id "message")
(declare-function gnus-setup-posting-charset "gnus-msg" (group))
(autoload 'gnus-completing-read "gnus-util")
(autoload 'message-fetch-field "message")
(autoload 'message-info "message")
(autoload 'fill-flowed-encode "flow-fill")
(autoload 'message-posting-charset "message")
(autoload 'dnd-get-local-file-name "dnd")

(autoload 'message-options-set    "message")
(autoload 'message-narrow-to-head "message")
(autoload 'message-in-body-p      "message")
(autoload 'message-mail-p         "message")

(defvar gnus-article-mime-handles)
(defvar gnus-newsrc-hashtb)
(defvar message-deletable-headers)
(defvar message-options)
(defvar message-posting-charset)
(defvar message-required-mail-headers)
(defvar message-required-news-headers)
(defvar dnd-protocol-alist)
(defvar mml-dnd-protocol-alist)

(defcustom mml-content-type-parameters
  '(name access-type expiration size permission format)
  "A list of acceptable parameters in MML tag.
These parameters are generated in Content-Type header if exists."
  :version "22.1"
  :type '(repeat (symbol :tag "Parameter"))
  :group 'message)

(defcustom mml-content-disposition-parameters
  '(filename creation-date modification-date read-date)
  "A list of acceptable parameters in MML tag.
These parameters are generated in Content-Disposition header if exists."
  :version "22.1"
  :type '(repeat (symbol :tag "Parameter"))
  :group 'message)

(defcustom mml-content-disposition-alist
  '((text (rtf . "attachment") (t . "inline"))
    (t . "attachment"))
  "Alist of MIME types or regexps matching file names and default dispositions.
Each element should be one of the following three forms:

  (REGEXP . DISPOSITION)
  (SUPERTYPE (SUBTYPE . DISPOSITION) (SUBTYPE . DISPOSITION)...)
  (TYPE . DISPOSITION)

Where REGEXP is a string which matches the file name (if any) of an
attachment, SUPERTYPE, SUBTYPE and TYPE should be symbols which are a
MIME supertype (e.g., text), a MIME subtype (e.g., plain) and a MIME
type (e.g., text/plain) respectively, and DISPOSITION should be either
the string \"attachment\" or the string \"inline\".  The value t for
SUPERTYPE, SUBTYPE or TYPE matches any of those types.  The first
match found will be used."
  :version "23.1" ;; No Gnus
  :type (let ((dispositions '(radio :format "DISPOSITION: %v"
				    :value "attachment"
				    (const :format "%v " "attachment")
				    (const :format "%v\n" "inline"))))
	  `(repeat
	    :offset 0
	    (choice :format "%[Value Menu%]%v"
		    (cons :tag "(REGEXP . DISPOSITION)" :extra-offset 4
			  (regexp :tag "REGEXP" :value ".*")
			  ,dispositions)
		    (cons :tag "(SUPERTYPE (SUBTYPE . DISPOSITION)...)"
			  :indent 0
			  (symbol :tag "    SUPERTYPE" :value text)
			  (repeat :format "%v%i\n" :offset 0 :extra-offset 4
				  (cons :format "%v" :extra-offset 5
					(symbol :tag "SUBTYPE" :value t)
					,dispositions)))
		    (cons :tag "(TYPE . DISPOSITION)" :extra-offset 4
			  (symbol :tag "TYPE" :value t)
			  ,dispositions))))
  :group 'message)

(defcustom mml-insert-mime-headers-always t
  "If non-nil, always put Content-Type: text/plain at top of empty parts.
It is necessary to work against a bug in certain clients."
  :version "24.1"
  :type 'boolean
  :group 'message)

(defcustom mml-enable-flowed t
  "If non-nil, enable format=flowed usage when encoding a message.
This is only performed when filling on text/plain with hard
newlines in the text."
  :version "24.1"
  :type 'boolean
  :group 'message)

(defvar mml-tweak-type-alist nil
  "A list of (TYPE . FUNCTION) for tweaking MML parts.
TYPE is a string containing a regexp to match the MIME type.  FUNCTION
is a Lisp function which is called with the MML handle to tweak the
part.  This variable is used only when no TWEAK parameter exists in
the MML handle.")

(defvar mml-tweak-function-alist nil
  "A list of (NAME . FUNCTION) for tweaking MML parts.
NAME is a string containing the name of the TWEAK parameter in the MML
handle.  FUNCTION is a Lisp function which is called with the MML
handle to tweak the part.")

(defvar mml-tweak-sexp-alist
  '((mml-externalize-attachments . mml-tweak-externalize-attachments))
  "A list of (SEXP . FUNCTION) for tweaking MML parts.
SEXP is an s-expression.  If the evaluation of SEXP is non-nil, FUNCTION
is called.  FUNCTION is a Lisp function which is called with the MML
handle to tweak the part.")

(defvar mml-externalize-attachments nil
  "If non-nil, local-file attachments are generated as external parts.")

(defcustom mml-generate-multipart-alist nil
  "Alist of multipart generation functions.
Each entry has the form (NAME . FUNCTION), where
NAME is a string containing the name of the part (without the
leading \"/multipart/\"),
FUNCTION is a Lisp function which is called to generate the part.

The Lisp function has to supply the appropriate MIME headers and the
contents of this part."
  :group 'message
  :type '(alist :key-type string :value-type function))

(defvar mml-syntax-table
  (let ((table (copy-syntax-table emacs-lisp-mode-syntax-table)))
    (modify-syntax-entry ?\\ "/" table)
    (modify-syntax-entry ?< "(" table)
    (modify-syntax-entry ?> ")" table)
    (modify-syntax-entry ?@ "w" table)
    (modify-syntax-entry ?/ "w" table)
    (modify-syntax-entry ?= " " table)
    (modify-syntax-entry ?* " " table)
    (modify-syntax-entry ?\; " " table)
    (modify-syntax-entry ?\' " " table)
    table))

(defvar mml-boundary-function 'mml-make-boundary
  "A function called to suggest a boundary.
The function may be called several times, and should try to make a new
suggestion each time.  The function is called with one parameter,
which is a number that says how many times the function has been
called for this message.")

(defvar mml-confirmation-set nil
  "A list of symbols, each of which disables some warning.
`unknown-encoding': always send messages contain characters with
unknown encoding; `use-ascii': always use ASCII for those characters
with unknown encoding; `multipart': always send messages with more than
one charsets.")

(defvar mml-generate-default-type "text/plain"
  "Content type by which the Content-Type header can be omitted.
The Content-Type header will not be put in the MIME part if the type
equals the value and there's no parameter (e.g. charset, format, etc.)
and `mml-insert-mime-headers-always' is nil.  The value will be bound
to \"message/rfc822\" when encoding an article to be forwarded as a MIME
part.  This is for the internal use, you should never modify the value.")

(defvar mml-buffer-list nil)

(defun mml-generate-new-buffer (name)
  (let ((buf (generate-new-buffer name)))
    (push buf mml-buffer-list)
    buf))

(defun mml-destroy-buffers ()
  (let (kill-buffer-hook)
    (mapc #'kill-buffer (prog1 mml-buffer-list
                          (setq mml-buffer-list nil)))))

(defun mml-parse ()
  "Parse the current buffer as an MML document."
  (save-excursion
    (goto-char (point-min))
    (with-syntax-table mml-syntax-table
      (mml-parse-1))))

(defun mml-parse-1 ()
  "Parse the current buffer as an MML document."
  (let (struct tag point contents charsets warn use-ascii no-markup-p raw)
    (while (and (not (eobp))
		(not (looking-at "<#/multipart")))
      (cond
       ((looking-at "<#secure")
	;; The secure part is essentially a meta-meta tag, which
	;; expands to either a part tag if there are no other parts in
	;; the document or a multipart tag if there are other parts
	;; included in the message
	(let* (secure-mode
	       (taginfo (mml-read-tag))
	       (keyfile (cdr (assq 'keyfile taginfo)))
	       (certfiles (delq nil (mapcar (lambda (tag)
					      (if (eq (car-safe tag) 'certfile)
						  (cdr tag)))
					    taginfo)))
               (chainfiles (delq nil (mapcar (lambda (tag)
                                               (if (eq (car-safe tag) 'chainfile)
                                                   (cdr tag)))
                                             taginfo)))
	       (recipients (cdr (assq 'recipients taginfo)))
	       (sender (cdr (assq 'sender taginfo)))
	       (location (cdr (assq 'tag-location taginfo)))
	       (mode (cdr (assq 'mode taginfo)))
	       (method (cdr (assq 'method taginfo)))
	       tags)
	  (save-excursion
	    (setq secure-mode
		  (if (re-search-forward
		       "<#/?\\(multipart\\|part\\|external\\|mml\\)."
		       nil t)
		      "multipart"
		    "part")))
	  (save-excursion
	    (goto-char location)
	    (re-search-forward "<#secure[^\n]*>\n"))
	  (delete-region (match-beginning 0) (match-end 0))
	  (setq tags (cond ((string= mode "sign")
		            (list "sign" method))
		           ((string= mode "encrypt")
		            (list "encrypt" method))
		           ((string= mode "signencrypt")
		            (list "sign" method "encrypt" method))
		           (t
		            (error "Unknown secure mode %s" mode))))
	  (apply #'mml-insert-tag
		 secure-mode
		 `(,@tags
		   ,(if keyfile "keyfile")
		   ,keyfile
		   ,@(apply #'append
			    (mapcar (lambda (certfile)
				      (list "certfile" certfile))
				    certfiles))
                   ,@(apply #'append
                            (mapcar (lambda (chainfile)
                                      (list "chainfile" chainfile))
                                    chainfiles))
		   ,(if recipients "recipients")
		   ,recipients
		   ,(if sender "sender")
		   ,sender))
	  ;; restart the parse
	  (goto-char location)))
       ((looking-at "<#multipart")
	(push (nconc (mml-read-tag) (mml-parse-1)) struct))
       ((looking-at "<#external")
	(push (nconc (mml-read-tag) (list (cons 'contents (mml-read-part))))
	      struct))
       (t
	(if (or (looking-at "<#part") (looking-at "<#mml"))
	    (setq tag (mml-read-tag)
		  no-markup-p nil
		  warn nil)
	  (setq tag (list 'part (cons 'type "text/plain"))
		no-markup-p t
		warn t))
	(setq raw (cdr (assq 'raw tag))
	      point (point)
	      contents (mml-read-part (eq 'mml (car tag)))
	      charsets (cond
			(raw nil)
			((assq 'charset tag)
			 (list
			  (intern (downcase (cdr (assq 'charset tag))))))
			(t
			 (mm-find-mime-charset-region point (point)
						      mm-hack-charsets))))
	;; We have a part that already has a transfer encoding.  Undo
	;; that so that we don't double-encode later.
	(when (and raw
		   (cdr (assq 'data-encoding tag)))
	  (with-temp-buffer
	    (set-buffer-multibyte nil)
	    (insert contents)
	    (mm-decode-content-transfer-encoding
	     (intern (cdr (assq 'data-encoding tag)))
	     (cdr (assq 'type tag)))
	    (setq contents (buffer-string))))
	(when (and (not raw) (memq nil charsets))
	  (if (or (memq 'unknown-encoding mml-confirmation-set)
		  (message-options-get 'unknown-encoding)
		  (and (y-or-n-p "\
Message contains characters with unknown encoding.  Really send? ")
		       (message-options-set 'unknown-encoding t)))
	      (if (setq use-ascii
			(or (memq 'use-ascii mml-confirmation-set)
			    (message-options-get 'use-ascii)
			    (and (y-or-n-p "Use ASCII as charset? ")
				 (message-options-set 'use-ascii t))))
		  (setq charsets (delq nil charsets))
		(setq warn nil))
	    (error "Edit your message to remove those characters")))
	(if (or raw
		(eq 'mml (car tag))
		(< (length charsets) 2))
	    (if (or (not no-markup-p)
		    ;; Don't create blank parts.
		    (string-match "[^ \t\r\n]" contents))
		(push (nconc tag (list (cons 'contents contents)))
		      struct))
	  (let ((nstruct (mml-parse-singlepart-with-multiple-charsets
			  tag point (point) use-ascii)))
	    (when (and warn
		       (not (memq 'multipart mml-confirmation-set))
		       (not (message-options-get 'multipart))
		       (not (and (y-or-n-p (format "\
A message part needs to be split into %d charset parts.  Really send? "
						   (length nstruct)))
				 (message-options-set 'multipart t))))
	      (error "Edit your message to use only one charset"))
	    (setq struct (nconc nstruct struct)))))))
    (unless (eobp)
      (forward-line 1))
    (nreverse struct)))

(defun mml-parse-singlepart-with-multiple-charsets
  (orig-tag beg end &optional use-ascii)
  (save-excursion
    (save-restriction
      (narrow-to-region beg end)
      (goto-char (point-min))
      (let ((current (or (mm-mime-charset (mm-charset-after))
			 (and use-ascii 'us-ascii)))
	    charset struct space newline paragraph)
	(while (not (eobp))
	  (setq charset (mm-mime-charset (mm-charset-after)))
	  (cond
	   ;; The charset remains the same.
	   ((eq charset 'us-ascii))
	   ((or (and use-ascii (not charset))
		(eq charset current))
	    (setq space nil
		  newline nil
		  paragraph nil))
	   ;; The initial charset was ascii.
	   ((eq current 'us-ascii)
	    (setq current charset
		  space nil
		  newline nil
		  paragraph nil))
	   ;; We have a change in charsets.
	   (t
	    (push (append
		   orig-tag
		   (list (cons 'contents
			       (buffer-substring-no-properties
				beg (or paragraph newline space (point))))))
		  struct)
	    (setq beg (or paragraph newline space (point))
		  current charset
		  space nil
		  newline nil
		  paragraph nil)))
	  ;; Compute places where it might be nice to break the part.
	  (cond
	   ((memq (following-char) '(?  ?\t))
	    (setq space (1+ (point))))
	   ((and (eq (following-char) ?\n)
		 (not (bobp))
		 (eq (char-after (1- (point))) ?\n))
	    (setq paragraph (point)))
	   ((eq (following-char) ?\n)
	    (setq newline (1+ (point)))))
	  (forward-char 1))
	;; Do the final part.
	(unless (= beg (point))
	  (push (append orig-tag
			(list (cons 'contents
				    (buffer-substring-no-properties
				     beg (point)))))
		struct))
	struct))))

(defun mml-read-tag ()
  "Read a tag and return the contents."
  (let ((orig-point (point))
	contents name elem val)
    (forward-char 2)
    (setq name (buffer-substring-no-properties
		(point) (progn (forward-sexp 1) (point))))
    (skip-chars-forward " \t\n")
    (while (not (looking-at ">[ \t]*\n?"))
      (setq elem (buffer-substring-no-properties
		  (point) (progn (forward-sexp 1) (point))))
      (skip-chars-forward "= \t\n")
      (setq val (buffer-substring-no-properties
		 (point) (progn (forward-sexp 1) (point))))
      (when (string-match "\\`\"" val)
	(setq val (read val))) ;; inverse of prin1 in mml-insert-tag
      (push (cons (intern elem) val) contents)
      (skip-chars-forward " \t\n"))
    (goto-char (match-end 0))
    ;; Don't skip the leading space.
    ;;(skip-chars-forward " \t\n")
    ;; Put the tag location into the returned contents
    (setq contents (append (list (cons 'tag-location orig-point)) contents))
    (cons (intern name) (nreverse contents))))

(defun mml-buffer-substring-no-properties-except-some (start end)
  (let ((str (buffer-substring-no-properties start end))
	(bufstart start)
	tmp)
    ;; Copy over all hard newlines.
    (while (setq tmp (text-property-any start end 'hard t))
      (put-text-property (- tmp bufstart) (- tmp bufstart -1)
			 'hard t str)
      (setq start (1+ tmp)))
    ;; Copy over all `display' properties (which are usually images).
    (setq start bufstart)
    (while (setq tmp (text-property-not-all start end 'display nil))
      (put-text-property (- tmp bufstart) (- tmp bufstart -1)
			 'display (get-text-property tmp 'display)
			 str)
      (setq start (1+ tmp)))
    str))

(defun mml-read-part (&optional mml)
  "Return the buffer up till the next part, multipart or closing part or multipart.
If MML is non-nil, return the buffer up till the correspondent mml tag."
  (let ((beg (point)) (count 1))
    ;; If the tag ended at the end of the line, we go to the next line.
    (when (looking-at "[ \t]*\n")
      (forward-line 1))
    (if mml
	(progn
	  (while (and (> count 0) (not (eobp)))
	    (if (re-search-forward "<#\\(/\\)?mml." nil t)
		(setq count (+ count (if (match-beginning 1) -1 1)))
	      (goto-char (point-max))))
	  (mml-buffer-substring-no-properties-except-some
	   beg (if (> count 0)
		   (point)
		 (match-beginning 0))))
      (if (re-search-forward
	   "<#\\(/\\)?\\(multipart\\|part\\|external\\|mml\\)." nil t)
	  (prog1
	      (mml-buffer-substring-no-properties-except-some
	       beg (match-beginning 0))
	    (if (or (not (match-beginning 1))
		    (equal (match-string 2) "multipart"))
		(goto-char (match-beginning 0))
	      (when (looking-at "[ \t]*\n")
		(forward-line 1))))
	(mml-buffer-substring-no-properties-except-some
	 beg (goto-char (point-max)))))))

(defvar mml-boundary nil)
(defvar mml-base-boundary "-=-=")
(defvar mml-multipart-number 0)
(defvar mml-inhibit-compute-boundary nil)

(declare-function libxml-parse-html-region "xml.c"
		  (start end &optional base-url discard-comments))

(defun mml-generate-mime (&optional multipart-type content-type)
  "Generate a MIME message based on the current MML document.
MULTIPART-TYPE defaults to \"mixed\", but can also
be \"related\" or \"alternate\".

If CONTENT-TYPE (and there's only one part), override the content
type detected."
  (let ((cont (mml-parse))
	(mml-multipart-number mml-multipart-number)
	(options message-options))
    (if (not cont)
	nil
      (when (and (consp (car cont))
		 (= (length cont) 1)
		 content-type)
        (when-let* ((spec (assq 'type (cdr (car cont)))))
	  (setcdr spec content-type)))
      (when (fboundp 'libxml-parse-html-region)
	(setq cont (mapcar #'mml-expand-all-html-into-multipart-related cont)))
      (prog1
	  (with-temp-buffer
	    (set-buffer-multibyte nil)
	    (setq message-options options)
	    (cond
	     ((and (consp (car cont))
		   (= (length cont) 1))
	      (mml-generate-mime-1 (car cont)))
	     ((eq (car cont) 'multipart)
	      (mml-generate-mime-1 cont))
	     (t
	      (mml-generate-mime-1
	       (nconc (list 'multipart (cons 'type (or multipart-type "mixed")))
		      cont))))
	    (setq options message-options)
	    (buffer-string))
	(setq message-options options)))))

(defun mml-expand-all-html-into-multipart-related (cont)
  (cond ((and (eq (car cont) 'part)
	      (equal (cdr (assq 'type cont)) "text/html"))
	 (mml-expand-html-into-multipart-related cont))
	((eq (car cont) 'multipart)
	 (let ((cur (cdr cont)))
	   (while (consp cur)
	     (setcar cur (mml-expand-all-html-into-multipart-related (car cur)))
	     (setf cur (cdr cur))))
	 cont)
	(t cont)))

(defun mml-expand-html-into-multipart-related (cont)
  (let ((new-parts nil)
	(cid 1))
    (mm-with-multibyte-buffer
      (insert (cdr (assq 'contents cont)))
      (goto-char (point-min))
      (with-syntax-table mml-syntax-table
	(while (re-search-forward "<img\\b" nil t)
	  (goto-char (match-beginning 0))
	  (let* ((start (point))
		 (img (nth 2
			   (nth 2
				(libxml-parse-html-region
				 (point) (progn (forward-sexp) (point))))))
		 (end (point))
		 (parsed (url-generic-parse-url (cdr (assq 'src (cadr img))))))
	    (when (and (null (url-type parsed))
                       (not (zerop (length (url-filename parsed))))
		       (file-exists-p (url-filename parsed)))
	      (goto-char start)
	      (when (search-forward (url-filename parsed) end t)
		(let ((cid (format "fsf.%d" cid)))
		  (replace-match (concat "cid:" cid) t t)
		  (push (list cid (url-filename parsed)
			      (get-text-property start 'display))
			new-parts))
		(setq cid (1+ cid)))))))
      ;; We have local images that we want to include.
      (when new-parts
	(setcdr (assq 'contents cont) (buffer-string))
	(setq cont
	      (nconc (list 'multipart (cons 'type "related"))
		     (list cont)))
	(dolist (new-part (nreverse new-parts))
	  (setq cont
		(nconc cont
		       (list `(part (type . "image/png")
				    ,@(mml--possibly-alter-image
				       (nth 1 new-part)
				       (nth 2 new-part))
				    (id . ,(concat "<" (nth 0 new-part)
						   ">"))))))))
      cont)))

(autoload 'image-property "image")

;; FIXME presumably (built-in) ImageMagick could replace exiftool?
(defun mml--possibly-alter-image (file-name image)
  (if (or (null image)
	  (not (consp image))
	  (not (eq (car image) 'image))
	  (not (image-property image :rotation))
	  (not (executable-find "exiftool")))
      `((filename . ,file-name))
    `((filename . ,file-name)
      (buffer
       .
       ,(with-current-buffer (mml-generate-new-buffer " *mml rotation*")
	  (set-buffer-multibyte nil)
	  (call-process "exiftool"
			file-name
			(list (current-buffer) nil)
			nil
			(format "-Orientation#=%d"
				(cl-case (truncate
					  (image-property image :rotation))
				  (0 0)
				  (90 6)
				  (180 3)
				  (270 8)
				  (otherwise 0)))
			"-o" "-"
			"-")
	  (current-buffer))))))

(defun mml-generate-mime-1 (cont)
  (let ((mm-use-ultra-safe-encoding
	 (or mm-use-ultra-safe-encoding (assq 'sign cont))))
    (save-restriction
      (narrow-to-region (point) (point))
      (mml-tweak-part cont)
      (cond
       ((or (eq (car cont) 'part) (eq (car cont) 'mml))
	(let* ((raw (cdr (assq 'raw cont)))
	       (filename (cdr (assq 'filename cont)))
	       (type (or (cdr (assq 'type cont))
			 (if filename
			     (or (mm-default-file-type filename)
				 "application/octet-stream")
			   "text/plain")))
	       (charset (cdr (assq 'charset cont)))
	       (coding (mm-charset-to-coding-system charset))
	       encoding flowed coded)
	  (cond ((eq coding 'ascii)
		 (setq charset nil
		       coding nil))
		(charset
		 ;; The value of `charset' might be a bogus alias that
		 ;; `mm-charset-synonym-alist' provides, like `utf8',
		 ;; so we prefer the MIME charset that Emacs knows for
		 ;; the coding system `coding'.
		 (setq charset (or (mm-coding-system-to-mime-charset coding)
				   (intern (downcase charset))))))
	  (if (and (not raw)
		   (member (car (split-string type "/")) '("text" "message")))
	      (progn
		(with-temp-buffer
		  (cond
		   ((cdr (assq 'buffer cont))
		    (insert-buffer-substring (cdr (assq 'buffer cont))))
		   ((and filename
			 (not (equal (cdr (assq 'nofile cont)) "yes")))
		    (let ((coding-system-for-read coding))
		      (mm-insert-file-contents filename)))
		   ((eq 'mml (car cont))
		    (insert (cdr (assq 'contents cont))))
		   (t
		    (save-restriction
		      (narrow-to-region (point) (point))
		      (insert (cdr (assq 'contents cont)))
		      ;; Remove quotes from quoted tags.
		      (goto-char (point-min))
		      (while (re-search-forward
			      "<#!+/?\\(part\\|multipart\\|external\\|mml\\|secure\\)"
			      nil t)
			(delete-region (+ (match-beginning 0) 2)
				       (+ (match-beginning 0) 3))))))
		  (cond
		   ((eq (car cont) 'mml)
		    (let ((mml-boundary (mml-compute-boundary cont))
			  ;; It is necessary for the case where this
			  ;; function is called recursively since
			  ;; `m-g-d-t' will be bound to "message/rfc822"
			  ;; when encoding an article to be forwarded.
			  (mml-generate-default-type "text/plain"))
		      (mml-to-mime)
		      ;; Update handle so mml-compute-boundary can
		      ;; detect collisions with the nested parts.
		      (unless mml-inhibit-compute-boundary
			(setcdr (assoc 'contents cont) (buffer-string))))
		    (let ((mm-7bit-chars (concat mm-7bit-chars "\x1b")))
		      ;; ignore 0x1b, it is part of iso-2022-jp
		      (setq encoding (mm-body-7-or-8))))
		   ((string= (car (split-string type "/")) "message")
		    (let ((mm-7bit-chars (concat mm-7bit-chars "\x1b")))
		      ;; ignore 0x1b, it is part of iso-2022-jp
		      (setq encoding (mm-body-7-or-8))))
		   (t
		    ;; Only perform format=flowed filling on text/plain
		    ;; parts where there either isn't a format parameter
		    ;; in the mml tag or it says "flowed" and there
		    ;; actually are hard newlines in the text.
		    (let (use-hard-newlines)
		      (when (and mml-enable-flowed
				 (string= type "text/plain")
				 (not (string= (cdr (assq 'sign cont)) "pgp"))
				 (or (null (assq 'format cont))
				     (string= (cdr (assq 'format cont))
					      "flowed"))
				 (setq use-hard-newlines
				       (text-property-any
					(point-min) (point-max) 'hard 't)))
			(fill-flowed-encode)
			;; Indicate that `mml-insert-mime-headers' should
			;; insert a "; format=flowed" string unless the
			;; user has already specified it.
			(setq flowed (null (assq 'format cont)))))
		    ;; Prefer `utf-8' for text/calendar parts.
		    (if (or charset
			    (not (string= type "text/calendar")))
			(setq charset (mm-encode-body charset))
		      (let ((mm-coding-system-priorities
			     (cons 'utf-8 mm-coding-system-priorities)))
			(setq charset (mm-encode-body))))
		    (setq encoding (mm-body-encoding
				    charset (cdr (assq 'encoding cont))))))
		  (setq coded (buffer-string)))
		(mml-insert-mime-headers cont type charset encoding flowed)
		(insert "\n")
		(insert coded))
	    (with-temp-buffer
	      (set-buffer-multibyte nil)
	      (cond
	       ((cdr (assq 'buffer cont))
		;; multibyte string that inserted to a unibyte buffer
		;; will be converted to the unibyte version safely.
		(insert (with-current-buffer (cdr (assq 'buffer cont))
			  (buffer-string))))
	       ((and filename
		     (not (equal (cdr (assq 'nofile cont)) "yes")))
		(let ((coding-system-for-read mm-binary-coding-system))
		  (mm-insert-file-contents filename nil nil nil nil t))
		(unless charset
		  (setq charset (mm-coding-system-to-mime-charset
				 (mm-find-buffer-file-coding-system
				  filename)))))
	       (t
		(let ((contents (cdr (assq 'contents cont))))
		  (if (multibyte-string-p contents)
		      (progn
			(set-buffer-multibyte t)
			(insert contents)
			(unless raw
			  (setq charset	(mm-encode-body charset))))
		    (insert contents)))))
	      (if (setq encoding (cdr (assq 'encoding cont)))
		  (setq encoding (intern (downcase encoding))))
	      (setq encoding (mm-encode-buffer type encoding))
	      (setq coded (decode-coding-string (buffer-string) 'us-ascii)))
	    (mml-insert-mime-headers cont type charset encoding nil)
	    (insert "\n" coded))))
       ((eq (car cont) 'external)
	(insert "Content-Type: message/external-body")
	(let ((parameters (mml-parameter-string
			   cont '(expiration size permission)))
	      (name (cdr (assq 'name cont)))
	      (url (cdr (assq 'url cont))))
	  (when name
	    (setq name (mml-parse-file-name name))
	    (if (stringp name)
		(mml-insert-parameter
		 (mail-header-encode-parameter "name" name)
		 "access-type=local-file")
	      (mml-insert-parameter
	       (mail-header-encode-parameter
		"name" (file-name-nondirectory (nth 2 name)))
	       (mail-header-encode-parameter "site" (nth 1 name))
	       (mail-header-encode-parameter
		"directory" (file-name-directory (nth 2 name))))
	      (mml-insert-parameter
	       (concat "access-type="
		       (if (member (nth 0 name) '("ftp@" "anonymous@"))
			   "anon-ftp"
			 "ftp")))))
	  (when url
	    (mml-insert-parameter
	     (mail-header-encode-parameter "url" url)
	     "access-type=url"))
	  (when parameters
	    (mml-insert-parameter-string
	     cont '(expiration size permission)))
	  (insert "\n\n")
	  (insert "Content-Type: "
		  (or (cdr (assq 'type cont))
		      (if name
			  (or (mm-default-file-type name)
			      "application/octet-stream")
			"text/plain"))
		  "\n")
	  (insert "Content-ID: " (message-make-message-id) "\n")
	  (insert "Content-Transfer-Encoding: "
		  (or (cdr (assq 'encoding cont)) "binary"))
	  (insert "\n\n")
	  (insert (or (cdr (assq 'contents cont))))
	  (insert "\n")))
       ((eq (car cont) 'multipart)
	(let* ((type (or (cdr (assq 'type cont)) "mixed"))
	       (mml-generate-default-type (if (equal type "digest")
					      "message/rfc822"
					    "text/plain"))
	       (handler (assoc type mml-generate-multipart-alist)))
	  (if handler
	      (funcall (cdr handler) cont)
	    ;; No specific handler.  Use default one.
	    (let ((mml-boundary (mml-compute-boundary cont)))
	      (insert (format "Content-Type: multipart/%s; boundary=\"%s\""
			      type mml-boundary)
		      (if (cdr (assq 'start cont))
			  (format "; start=\"%s\"\n" (cdr (assq 'start cont)))
			"\n"))
	      (let ((cont cont) part)
		(while (setq part (pop cont))
		  ;; Skip `multipart' and attributes.
		  (when (and (consp part) (consp (cdr part)))
		    (insert "\n--" mml-boundary "\n")
		    (mml-generate-mime-1 part)
		    (goto-char (point-max)))))
	      (insert "\n--" mml-boundary "--\n")))))
       (t
	(error "Invalid element: %S" cont)))
      ;; handle sign & encrypt tags in a semi-smart way.
      (let ((sign-item (assoc (cdr (assq 'sign cont)) mml-sign-alist))
	    (encrypt-item (assoc (cdr (assq 'encrypt cont))
				 mml-encrypt-alist))
	    sender recipients)
	(when (or sign-item encrypt-item)
	  (when (setq sender (cdr (assq 'sender cont)))
	    (message-options-set 'mml-sender sender)
	    (message-options-set 'message-sender sender))
	  (if (setq recipients (cdr (assq 'recipients cont)))
	      (message-options-set 'message-recipients recipients))
	  (let ((style (mml-signencrypt-style
			(car (or sign-item encrypt-item)))))
	    ;; check if: we're both signing & encrypting, both methods
	    ;; are the same (why would they be different?!), and that
	    ;; the signencrypt style allows for combined operation.
	    (if (and sign-item encrypt-item (equal (car sign-item)
						   (car encrypt-item))
		     (equal style 'combined))
		(funcall (nth 1 encrypt-item) cont t)
	      ;; otherwise, revert to the old behavior.
	      (when sign-item
		(funcall (nth 1 sign-item) cont))
	      (when encrypt-item
		(funcall (nth 1 encrypt-item) cont)))))))))

(defun mml-compute-boundary (cont)
  "Return a unique boundary that does not exist in CONT."
  (let ((mml-boundary (funcall mml-boundary-function
                               (incf mml-multipart-number))))
    (unless mml-inhibit-compute-boundary
      ;; This function tries again and again until it has found
      ;; a unique boundary.
      (while (not (catch 'not-unique
		    (mml-compute-boundary-1 cont)))))
    mml-boundary))

(defun mml-compute-boundary-1 (cont)
  (cond
   ((member (car cont) '(part mml))
    (mm-with-multibyte-buffer
      (let ((mml-inhibit-compute-boundary t)
	    (mml-multipart-number 0)
	    mml-sign-alist mml-encrypt-alist)
	(mml-generate-mime-1 cont))
      (goto-char (point-min))
      (when (re-search-forward (concat "^--" (regexp-quote mml-boundary))
			       nil t)
	(setq mml-boundary (funcall mml-boundary-function
                                    (incf mml-multipart-number)))
	(throw 'not-unique nil))))
   ((eq (car cont) 'multipart)
    (mapc #'mml-compute-boundary-1 (cddr cont))))
  t)

(defun mml-make-boundary (number)
  (concat (make-string (% number 60) ?=)
	  (if (> number 17)
	      (format "%x" number)
	    "")
	  mml-base-boundary))

(defun mml-content-disposition (type &optional filename)
  "Return a default disposition name suitable to TYPE or FILENAME."
  (let ((defs mml-content-disposition-alist)
	disposition def types)
    (while (and (not disposition) defs)
      (setq def (pop defs))
      (cond ((stringp (car def))
	     (when (and filename
			(string-match (car def) filename))
	       (setq disposition (cdr def))))
	    ((consp (cdr def))
	     (when (string= (car (setq types (split-string type "/")))
			    (car def))
	       (setq type (cadr types)
		     types (cdr def))
	       (while (and (not disposition) types)
		 (setq def (pop types))
		 (when (or (eq (car def) t) (string= type (car def)))
		   (setq disposition (cdr def))))))
	    (t
	     (when (or (eq (car def) t) (string= type (car def)))
	       (setq disposition (cdr def))))))
    (or disposition "attachment")))

(defun mml-insert-mime-headers (cont type charset encoding flowed)
  (let (parameters id disposition description)
    (setq parameters
	  (mml-parameter-string
	   cont mml-content-type-parameters))
    (when (or charset
	      parameters
	      flowed
	      (not (equal type mml-generate-default-type))
	      mml-insert-mime-headers-always)
      (when (consp charset)
	(error
	 "Can't encode a part with several charsets"))
      (insert "Content-Type: " type)
      (when charset
	(mml-insert-parameter
	 (mail-header-encode-parameter "charset" (symbol-name charset))))
      (when flowed
	(mml-insert-parameter "format=flowed"))
      (when parameters
	(mml-insert-parameter-string
	 cont mml-content-type-parameters))
      (insert "\n"))
    (when (setq id (cdr (assq 'id cont)))
      (insert "Content-ID: " id "\n"))
    (setq parameters
	  (mml-parameter-string
	   cont mml-content-disposition-parameters))
    (when (or (setq disposition (cdr (assq 'disposition cont)))
	      parameters)
      (insert "Content-Disposition: "
	      (or disposition
		  (mml-content-disposition type (cdr (assq 'filename cont)))))
      (when parameters
	(let ((cont (copy-sequence cont)))
	  ;; Set the file name to what's specified by the user.
	  (when-let* ((recipient-filename (cdr (assq 'recipient-filename cont))))
	    (setcdr cont
		    (cons (cons 'filename recipient-filename)
			  (cdr cont))))
	  (mml-insert-parameter-string
	   cont mml-content-disposition-parameters)))
      (insert "\n"))
    (unless (eq encoding '7bit)
      (insert (format "Content-Transfer-Encoding: %s\n" encoding)))
    (when (setq description (cdr (assq 'description cont)))
      (insert "Content-Description: "
	      ;; The current buffer is unibyte, so do the description
	      ;; encoding in a temporary buffer.
	      (with-temp-buffer
		(insert description "\n")
		(mail-encode-encoded-word-region (point-min) (point-max))
		(buffer-string))))))

(defun mml-parameter-string (cont types)
  (let ((string "")
	value type)
    (while (setq type (pop types))
      (when (setq value (cdr (assq type cont)))
	;; Strip directory component from the filename parameter.
	(when (eq type 'filename)
	  (setq value (file-name-nondirectory value)))
	(setq string (concat string "; "
			     (mail-header-encode-parameter
			      (symbol-name type) value)))))
    (when (not (zerop (length string)))
      string)))

(defun mml-insert-parameter-string (cont types)
  (let (value type)
    (while (setq type (pop types))
      (when (setq value (cdr (assq type cont)))
	;; Strip directory component from the filename parameter.
	(when (eq type 'filename)
	  (setq value (file-name-nondirectory value)))
	(mml-insert-parameter
	 (mail-header-encode-parameter
	  (symbol-name type) value))))))

(defvar ange-ftp-name-format)

(defun mml-parse-file-name (path)
  (if (and (boundp 'ange-ftp-name-format)
           (string-match (car ange-ftp-name-format) path))
      (list (match-string 1 path) (match-string 2 path)
	    (substring path (1+ (match-end 2))))
    path))

(defun mml-insert-buffer (buffer)
  "Insert BUFFER at point and quote any MML markup."
  (save-restriction
    (narrow-to-region (point) (point))
    (insert-buffer-substring buffer)
    (mml-quote-region (point-min) (point-max))
    (goto-char (point-max))))

;;;
;;; Transforming MIME to MML
;;;

;; message-narrow-to-head autoloads message.
(declare-function message-remove-header "message"
                  (header &optional is-regexp first reverse))

(defun mime-to-mml (&optional handles)
  "Translate the current buffer (which should be a message) into MML.
If HANDLES is non-nil, use it instead reparsing the buffer."
  ;; First decode the head.
  (save-restriction
    (message-narrow-to-head)
    (let ((rfc2047-quote-decoded-words-containing-tspecials t))
      (mail-decode-encoded-word-region (point-min) (point-max))))
  (unless handles
    (setq handles (mm-dissect-buffer t)))
  (goto-char (point-min))
  (if (search-forward "\n\n" nil 'move)
      (delete-region (point) (point-max))
    ;; No content in the part that is the sole part of this message.
    (insert (if (bolp) "\n" "\n\n")))
  (if (stringp (car handles))
      (mml-insert-mime handles)
    (mml-insert-mime handles t))
  (mm-destroy-parts handles)
  (save-restriction
    (message-narrow-to-head)
    ;; Remove them, they are confusing.
    (message-remove-header "Content-Type")
    (message-remove-header "MIME-Version")
    (message-remove-header "Content-Disposition")
    (message-remove-header "Content-Transfer-Encoding")))

(autoload 'message-encode-message-body "message")
(autoload 'message-narrow-to-headers-or-head "message")
(declare-function message-narrow-to-headers-or-head "message" ())

;;;###autoload
(defun mml-to-mime ()
  "Translate the current buffer from MML to MIME."
  ;; `message-encode-message-body' will insert an encoded Content-Description
  ;; header in the message header if the body contains a single part
  ;; that is specified by a user with a MML tag containing a description
  ;; token.  So, we encode the message header first to prevent the encoded
  ;; Content-Description header from being encoded again.
  (save-restriction
    (message-narrow-to-headers-or-head)
    ;; Skip past any From_ headers.
    (while (looking-at "From ")
      (forward-line 1))
    (mail-encode-encoded-word-buffer))
  (message-encode-message-body))

(defun mml-insert-mime (handle &optional no-markup)
  (let (textp buffer mmlp)
    ;; Determine type and stuff.
    (unless (stringp (car handle))
      (unless (setq textp (equal (mm-handle-media-supertype handle) "text"))
	(with-current-buffer (setq buffer (mml-generate-new-buffer " *mml*"))
	  (if (eq (mail-content-type-get (mm-handle-type handle) 'charset)
		  'gnus-decoded)
	      ;; A part that mm-uu dissected from a non-MIME message
	      ;; because of `gnus-article-emulate-mime'.
	      (progn
		(mm-enable-multibyte)
		(insert-buffer-substring (mm-handle-buffer handle)))
	    (mm-insert-part handle 'no-cache)
	    (if (setq mmlp (equal (mm-handle-media-type handle)
				  "message/rfc822"))
		(mime-to-mml))))))
    (if mmlp
	(mml-insert-mml-markup handle nil t t)
      (unless (and no-markup
		   (equal (mm-handle-media-type handle) "text/plain"))
	(mml-insert-mml-markup handle buffer textp)))
    (cond
     (mmlp
      (insert-buffer-substring buffer)
      (goto-char (point-max))
      (insert "<#/mml>\n"))
     ((stringp (car handle))
      (mapc #'mml-insert-mime (cdr handle))
      (insert "<#/multipart>\n"))
     (textp
      (let ((charset (mail-content-type-get
		      (mm-handle-type handle) 'charset))
	    (start (point)))
	(if (eq charset 'gnus-decoded)
	    (mm-insert-part handle)
	  (insert (mm-decode-string (mm-get-part handle) charset)))
	(mml-quote-region start (point)))
      (goto-char (point-max)))
     (t
      (insert "<#/part>\n")))))

(defun mml-insert-mml-markup (handle &optional buffer nofile mmlp)
  "Take a MIME handle and insert an MML tag."
  (if (stringp (car handle))
      (progn
	(insert "<#multipart type=" (mm-handle-media-subtype handle))
	(let ((start (mm-handle-multipart-ctl-parameter handle 'start)))
	  (when start
	    (insert " start=\"" start "\"")))
	(insert ">\n"))
    (if mmlp
	(insert "<#mml type=" (mm-handle-media-type handle))
      (insert "<#part type=" (mm-handle-media-type handle)))
    (dolist (elem (append (cdr (mm-handle-type handle))
			  (cdr (mm-handle-disposition handle))))
      (unless (symbolp (cdr elem))
	(insert " " (symbol-name (car elem)) "=\"" (cdr elem) "\"")))
    (when (mm-handle-id handle)
      (insert " id=\"" (mm-handle-id handle) "\""))
    (when (mm-handle-disposition handle)
      (insert " disposition=" (car (mm-handle-disposition handle))))
    (when buffer
      (insert " buffer=\"" (buffer-name buffer) "\""))
    (when nofile
      (insert " nofile=yes"))
    (when (mm-handle-description handle)
      (insert " description=\"" (mm-handle-description handle) "\""))
    (insert ">\n")))

(defun mml-insert-parameter (&rest parameters)
  "Insert PARAMETERS in a nice way."
  (let (start end)
    (dolist (param parameters)
      (insert ";")
      (setq start (point))
      (insert " " param)
      (setq end (point))
      (goto-char start)
      (end-of-line)
      (if (> (current-column) 76)
	  (progn
	    (goto-char start)
	    (insert "\n")
	    (goto-char (1+ end)))
	(goto-char end)))))

;;;
;;; Mode for inserting and editing MML forms
;;;

(defvar-keymap mml-mode-map
  "C-c C-m"
  (define-keymap
    "C-s" #'mml-secure-message-sign
    "C-c" #'mml-secure-message-encrypt
    "C-e" #'mml-secure-message-sign-encrypt
    "C-p C-s" #'mml-secure-sign
    "C-p C-c" #'mml-secure-encrypt

    "s" (define-keymap
          "p" #'mml-secure-message-sign-pgpmime
          "o" #'mml-secure-message-sign-pgp
          "s" #'mml-secure-message-sign-smime)
    "S" (define-keymap
          "p" #'mml-secure-sign-pgpmime
          "o" #'mml-secure-sign-pgp
          "s" #'mml-secure-sign-smime)
    "c" (define-keymap
          "p" #'mml-secure-message-encrypt-pgpmime
          "o" #'mml-secure-message-encrypt-pgp
          "s" #'mml-secure-message-encrypt-smime)
    "C" (define-keymap
          "p" #'mml-secure-encrypt-pgpmime
          "o" #'mml-secure-encrypt-pgp
          "s" #'mml-secure-encrypt-smime)
    "C-n" #'mml-unsecure-message
    "f" #'mml-attach-file
    "b" #'mml-attach-buffer
    "e" #'mml-attach-external
    "q" #'mml-quote-region
    "m" #'mml-insert-multipart
    "p" #'mml-insert-part
    "v" #'mml-validate
    "P" #'mml-preview))

(easy-menu-define
  mml-menu mml-mode-map ""
  '("Attachments"
    ["Attach File..." mml-attach-file :help "Attach a file at point"]
    ["Attach Buffer..." mml-attach-buffer
     :help "Attach a buffer to the outgoing message"]
    ["Attach External..." mml-attach-external
     :help "Attach reference to an external file"]
    ;; FIXME: Is it possible to do this without using
    ;; `gnus-gcc-externalize-attachments'?
    ["Externalize Attachments"
     (lambda ()
       (interactive)
       (setq gnus-gcc-externalize-attachments
	     (not gnus-gcc-externalize-attachments))
       (message "gnus-gcc-externalize-attachments is `%s'."
		gnus-gcc-externalize-attachments))
     :visible (and (boundp 'gnus-gcc-externalize-attachments)
		   (memq gnus-gcc-externalize-attachments
			 '(all t nil)))
     :style toggle
     :selected gnus-gcc-externalize-attachments
     :help "Save attachments as external parts in Gcc copies"]
    "----"
    ;;
    ("Change Security Method"
     ["PGP/MIME"
      (lambda () (interactive) (setq mml-secure-method "pgpmime"))
      :help "Set Security Method to PGP/MIME"
      :style radio
      :selected (equal mml-secure-method "pgpmime") ]
     ["S/MIME"
      (lambda () (interactive) (setq mml-secure-method "smime"))
      :help "Set Security Method to S/MIME"
      :style radio
      :selected (equal mml-secure-method "smime") ]
     ["Inline PGP"
      (lambda () (interactive) (setq mml-secure-method "pgp"))
      :help "Set Security Method to inline PGP"
      :style radio
      :selected (equal mml-secure-method "pgp") ] )
    ;;
    ["Sign Message" mml-secure-message-sign t]
    ["Encrypt Message" mml-secure-message-encrypt t]
    ["Sign and Encrypt Message" mml-secure-message-sign-encrypt t]
    ["Encrypt/Sign off" mml-unsecure-message
     :help "Don't Encrypt/Sign Message"]
    ;; Do we have separate encrypt and encrypt/sign commands for parts?
    ["Sign Part" mml-secure-sign t]
    ["Encrypt Part" mml-secure-encrypt t]
    "----"
    ;; Maybe we could remove these, because people who write MML most probably
    ;; don't use the menu:
    ["Insert Part..." mml-insert-part
     :active (message-in-body-p)]
    ["Insert Multipart..." mml-insert-multipart
     :active (message-in-body-p)]
    ;;
    ;;["Narrow" mml-narrow-to-part t]
    ["Quote MML in region" mml-quote-region
     :active mark-active
     :help "Quote MML tags in region"]
    ["Validate MML" mml-validate t]
    ["Preview" mml-preview t]
    "----"
    ["Emacs MIME manual" (lambda () (interactive) (message-info 4))
     :help "Display the Emacs MIME manual"]
    ["PGG manual" (lambda () (interactive) (message-info mml2015-use))
     :visible (and (boundp 'mml2015-use) (equal mml2015-use 'pgg))
     :help "Display the PGG manual"]
    ["EasyPG manual" (lambda () (interactive) (require 'mml2015) (message-info mml2015-use))
     :visible (and (boundp 'mml2015-use) (equal mml2015-use 'epg))
     :help "Display the EasyPG manual"]))

(define-minor-mode mml-mode
  "Minor mode for editing MML.
MML is the MIME Meta Language, a minor mode for composing MIME articles.
See Info node `(emacs-mime)Composing'.

\\{mml-mode-map}"
  :lighter " MML" :keymap mml-mode-map
  (when mml-mode
    (when (boundp 'dnd-protocol-alist)
      (setq-local dnd-protocol-alist
                  (append mml-dnd-protocol-alist dnd-protocol-alist)))))

;;;
;;; Helper functions for reading MIME stuff from the minibuffer and
;;; inserting stuff to the buffer.
;;;

(defcustom mml-default-directory mm-default-directory
  "The default directory where mml will find files.
If not set, `default-directory' will be used."
  :type '(choice directory (const :tag "Default" nil))
  :version "23.1" ;; No Gnus
  :group 'message)

(defun mml-minibuffer-read-file (prompt)
  (let* ((completion-ignored-extensions nil)
	 (buffer-file-name nil)
	 (file (read-file-name prompt
			       (or mml-default-directory default-directory)
			       nil t)))
    ;; Prevent some common errors.  This is inspired by similar code in
    ;; VM.
    (when (file-directory-p file)
      (error "%s is a directory, cannot attach" file))
    (unless (file-exists-p file)
      (error "No such file: %s" file))
    (unless (file-readable-p file)
      (error "Permission denied: %s" file))
    file))

(declare-function mailcap-parse-mimetypes "mailcap" (&optional path force))
(declare-function mailcap-mime-types "mailcap" ())

(defun mml-minibuffer-read-type (name &optional default)
  (require 'mailcap)
  (mailcap-parse-mimetypes)
  (let* ((default (or default
		      (mm-default-file-type name)
		      ;; Perhaps here we should check what the file
		      ;; looks like, and offer text/plain if it looks
		      ;; like text/plain.
		      "application/octet-stream"))
	 (string (gnus-completing-read
		  "Content type"
		  (mailcap-mime-types)
                  nil nil nil default)))
    (if (not (equal string ""))
	string
      default)))

(defun mml-minibuffer-read-description (&optional default)
  (let ((description (read-string "One line description: " default)))
    (when (string-match "\\`[ \t]*\\'" description)
      (setq description nil))
    description))

(defun mml-minibuffer-read-disposition (type &optional default filename)
  (unless default
    (setq default (mml-content-disposition type filename)))
  (let ((disposition (gnus-completing-read
		      "Disposition"
		      '("attachment" "inline")
		      t nil nil default)))
    (if (not (equal disposition ""))
	disposition
      default)))

(defun mml-quote-region (beg end)
  "Quote the MML tags in the region."
  (interactive "r" mml-mode)
  (save-excursion
    (save-restriction
      ;; Temporarily narrow the region to defend from changes
      ;; invalidating END.
      (narrow-to-region beg end)
      (goto-char (point-min))
      ;; Quote parts.
      (while (re-search-forward
	      "<#!*/?\\(multipart\\|part\\|external\\|mml\\|secure\\)" nil t)
	;; Insert ! after the #.
	(goto-char (+ (match-beginning 0) 2))
	(insert "!")))))

(defun mml-insert-tag (name &rest plist)
  "Insert an MML tag described by NAME and PLIST."
  (when (symbolp name)
    (setq name (symbol-name name)))
  (insert "<#" name)
  (while plist
    (let ((key (pop plist))
	  (value (pop plist)))
      (when value
	;; Quote VALUE if it contains suspicious characters.
	(when (string-match "[][\"'\\~/*;()<>= \t\n[:multibyte:]]" value)
	  (setq value (with-output-to-string
			(let (print-escape-nonascii)
			  (prin1 value)))))
	(insert (format " %s=%s" key value)))))
  (insert ">\n"))

(defun mml-insert-empty-tag (name &rest plist)
  "Insert an empty MML tag described by NAME and PLIST."
  (when (symbolp name)
    (setq name (symbol-name name)))
  (apply #'mml-insert-tag name plist)
  (insert "<#/" name ">\n"))

;;; Attachment functions.

(defcustom mml-dnd-protocol-alist
  '(("^file:///" . mml-dnd-attach-file) ; GNOME, KDE, and suchlike.
    ("^file:/[^/]" . mml-dnd-attach-file) ; Motif, other systems.
    ("^file:[^/]" . mml-dnd-attach-file)) ; MS-Windows.
  "The functions to call when a drop in `mml-mode' is made.
See `dnd-protocol-alist' for more information.  When nil, behave
as in other buffers."
  :type '(choice (repeat (cons (regexp) (function)))
		 (const :tag "Behave as in other buffers" nil))
  :version "22.1" ;; Gnus 5.10.9
  :group 'message)

(defcustom mml-dnd-attach-options nil
  "Which options should be queried when attaching a file via drag and drop.

If it is a list, valid members are `type', `description' and
`disposition'.  `disposition' implies `type'.  If it is nil,
don't ask for options.  If it is t, ask the user whether or not
to specify options."
  :type '(choice
	  (const :tag "None" nil)
	  (const :tag "Query" t)
	  (list :value (type description disposition)
	   (set :inline t
		(const type)
		(const description)
		(const disposition))))
  :version "22.1" ;; Gnus 5.10.9
  :group 'message)

(defcustom mml-attach-file-at-the-end nil
  "If non-nil, \\[mml-attach-file] attaches files at the end of the message.
If nil, files are attached at point."
  :type 'boolean
  :version "29.1"
  :group 'message)

;;;###autoload
(defun mml-attach-file (file &optional type description disposition)
  "Attach a file to the outgoing MIME message.
The file is not inserted or encoded until you send the message with
`\\[message-send-and-exit]' or `\\[message-send]' in Message mode,
or `\\[mail-send-and-exit]' or `\\[mail-send]' in Mail mode.

FILE is the name of the file to attach.  TYPE is its
content-type, a string of the form \"type/subtype\".  DESCRIPTION
is a one-line description of the attachment.  The DISPOSITION
specifies how the attachment is intended to be displayed.  It can
be either \"inline\" (displayed automatically within the message
body) or \"attachment\" (separate from the body).

Also see the `mml-attach-file-at-the-end' variable.

If given a prefix interactively, no prompting will be done for
the TYPE, DESCRIPTION or DISPOSITION values.  Instead defaults
will be computed and used."
  (interactive
   (let* ((file (mml-minibuffer-read-file "Attach file: "))
	  (type (if current-prefix-arg
		    (or (mm-default-file-type file)
			"application/octet-stream")
		  (mml-minibuffer-read-type file)))
	  (description (if current-prefix-arg
			   nil
			 (mml-minibuffer-read-description)))
	  (disposition (if current-prefix-arg
			   (mml-content-disposition type file)
			 (mml-minibuffer-read-disposition type nil file))))
     (list file type description disposition)))
  ;; If in the message header, attach at the end and leave point unchanged.
  (let ((at-end (and (or (not (message-in-body-p))
                         mml-attach-file-at-the-end)
                     (point))))
    (when at-end
      (goto-char (point-max)))
    (mml-insert-empty-tag 'part
			  'type type
			  ;; icicles redefines read-file-name and returns a
                          ;; string with text properties :-/
			  'filename (substring-no-properties file)
			  'disposition (or disposition "attachment")
			  'description description)
    ;; When using Mail mode, make sure it does the mime encoding
    ;; when you send the message.
    (unless (eq mail-user-agent 'message-user-agent)
      (setq mail-encode-mml t))
    (when at-end
      (unless (pos-visible-in-window-p)
	(message "The file \"%s\" has been attached at the end of the message"
		 (file-name-nondirectory file)))
      (goto-char at-end))))

(defun mml-dnd-attach-file (uris _action)
  "Attach a drag and drop URIS, a list of local file URIs.

Query whether to use the types, dispositions and descriptions
default for each URL, subject to `mml-dnd-attach-options'.

Return the action `private', communicating to the drop source
that the file has been attached."
  (let (file (mml-dnd-attach-options mml-dnd-attach-options))
    (setq mml-dnd-attach-options
	  (when (and (eq mml-dnd-attach-options t)
		     (not
		      (y-or-n-p
		       "Use default type, disposition and description? ")))
	    '(type description disposition)))
    (dolist (uri uris)
      (setq file (dnd-get-local-file-name uri t))
      (when (and file (file-regular-p file))
        (let (type description disposition)
	  (when (or (memq 'type mml-dnd-attach-options)
		    (memq 'disposition mml-dnd-attach-options))
	    (setq type (mml-minibuffer-read-type file)))
	  (when (memq 'description mml-dnd-attach-options)
	    (setq description (mml-minibuffer-read-description)))
	  (when (memq 'disposition mml-dnd-attach-options)
	    (setq disposition (mml-minibuffer-read-disposition type nil file)))
	  (mml-attach-file file type description disposition)))))
  'private)

(put 'mml-dnd-attach-file 'dnd-multiple-handler t)

(defun mml-attach-buffer (buffer &optional type description disposition filename)
  "Attach a buffer to the outgoing MIME message.
BUFFER is the name of the buffer to attach.  See
`mml-attach-file' regarding TYPE, DESCRIPTION and DISPOSITION.
FILENAME is a suggested file name for the attachment should a
recipient wish to save a copy separate from the message."
  (interactive
   (let* ((buffer (read-buffer "Attach buffer: "))
	  (type (mml-minibuffer-read-type
                 buffer (mm-default-buffer-type buffer)))
	  (description (mml-minibuffer-read-description))
	  (disposition (mml-minibuffer-read-disposition type nil)))
     (list buffer type description disposition)))
  ;; If in the message header, attach at the end and leave point unchanged.
  (let ((head (unless (message-in-body-p) (point))))
    (if head (goto-char (point-max)))
    (apply #'mml-insert-empty-tag
           'part 'type type 'buffer buffer
	   'disposition disposition 'description description
           (and filename `(filename ,filename)))
    ;; When using Mail mode, make sure it does the mime encoding
    ;; when you send the message.
    (or (eq mail-user-agent 'message-user-agent)
	(setq mail-encode-mml t))
    (when head
      (unless (pos-visible-in-window-p)
	(message
	 "The buffer \"%s\" has been attached at the end of the message"
	 buffer))
      (goto-char head))))

(defun mml-attach-external (file &optional type description)
  "Attach an external file into the buffer.
FILE is an ange-ftp specification of the part location.
TYPE is the MIME type to use."
  (interactive
   (let* ((file (mml-minibuffer-read-file "Attach external file: "))
	  (type (mml-minibuffer-read-type file))
	  (description (mml-minibuffer-read-description)))
     (list file type description)))
  ;; If in the message header, attach at the end and leave point unchanged.
  (let ((head (unless (message-in-body-p) (point))))
    (if head (goto-char (point-max)))
    (mml-insert-empty-tag 'external 'type type 'name file
			  'disposition "attachment" 'description description)
    ;; When using Mail mode, make sure it does the mime encoding
    ;; when you send the message.
    (or (eq mail-user-agent 'message-user-agent)
	(setq mail-encode-mml t))
    (when head
      (unless (pos-visible-in-window-p)
	(message "The file \"%s\" has been attached at the end of the message"
		 (file-name-nondirectory file)))
      (goto-char head))))

(defun mml-insert-multipart (&optional type)
  (interactive (if (message-in-body-p)
		   (list (gnus-completing-read "Multipart type"
                                               '("mixed" "alternative"
                                                 "digest" "parallel"
                                                 "signed" "encrypted")
                                               nil "mixed"))
		 (error "Use this command in the message body")))
  (or type
      (setq type "mixed"))
  (mml-insert-empty-tag "multipart" 'type type)
  ;; When using Mail mode, make sure it does the mime encoding
  ;; when you send the message.
  (or (eq mail-user-agent 'message-user-agent)
      (setq mail-encode-mml t))
  (forward-line -1))

(defun mml-insert-part (&optional type)
  (interactive (if (message-in-body-p)
		   (list (mml-minibuffer-read-type ""))
		 (error "Use this command in the message body")))
  ;; When using Mail mode, make sure it does the mime encoding
  ;; when you send the message.
  (or (eq mail-user-agent 'message-user-agent)
      (setq mail-encode-mml t))
  (mml-insert-tag 'part 'type type 'disposition "inline")
  (save-excursion
    (mml-insert-tag '/part)))

(declare-function message-subscribed-p "message" ())
(declare-function message-make-mail-followup-to "message"
                  (&optional only-show-subscribed))
(declare-function message-position-on-field "message" (header &rest afters))

(defun mml-preview-insert-mail-followup-to ()
  "Insert a Mail-Followup-To header before previewing an article.
Should be adopted if code in `message-send-mail' is changed."
  (when (and (message-mail-p)
	     (message-subscribed-p)
	     (not (mail-fetch-field "mail-followup-to"))
	     (message-make-mail-followup-to))
    (message-position-on-field "Mail-Followup-To" "X-Draft-From")
    (insert (message-make-mail-followup-to))))

(defvar mml-preview-buffer nil)

(autoload 'widget-button-press "wid-edit" nil t)
(declare-function widget-event-point "wid-edit" (event))
;; If gnus-buffer-configuration is bound this is loaded.
(declare-function gnus-configure-windows "gnus-win" (setting &optional force))
;; Called after message-mail-p, which autoloads message.
(declare-function message-news-p                "message" ())
(declare-function message-options-set-recipient "message" ())
(declare-function message-generate-headers      "message" (headers))
(declare-function message-sort-headers          "message" ())

(defvar gnus-newsgroup-name)
(defvar gnus-displaying-mime)
(defvar gnus-newsgroup-name)
(defvar gnus-article-prepare-hook)
(defvar gnus-newsgroup-charset)
(defvar gnus-original-article-buffer)
(defvar gnus-message-buffer)
(defvar message-this-is-news)
(defvar message-this-is-mail)

(defun mml-preview (&optional raw)
  "Display current buffer with Gnus, in a new buffer.
If RAW, display a raw encoded MIME message.

The window layout for the preview buffer is controlled by the variables
`special-display-buffer-names', `special-display-regexps', or
`gnus-buffer-configuration' (the first match made will be used),
or the `pop-to-buffer' function."
  (interactive "P")
  (setq mml-preview-buffer (generate-new-buffer
			    (concat (if raw "*Raw MIME preview of "
				      "*MIME preview of ")
				    (buffer-name))))
  (require 'gnus-msg)		      ; for gnus-setup-posting-charset
  (save-excursion
    (let* ((buf (current-buffer))
	   (article-editing (eq major-mode 'gnus-article-edit-mode))
	   (message-options message-options)
	   (message-this-is-mail (message-mail-p))
	   (message-this-is-news (message-news-p))
	   (message-posting-charset (or (gnus-setup-posting-charset
					 (save-restriction
					   (message-narrow-to-headers-or-head)
					   (message-fetch-field "Newsgroups")))
					message-posting-charset)))
      (message-options-set-recipient)
      (when (boundp 'gnus-buffers)
	(push mml-preview-buffer gnus-buffers))
      (save-restriction
	(widen)
	(set-buffer mml-preview-buffer)
	(erase-buffer)
	(insert-buffer-substring buf))
      (mml-preview-insert-mail-followup-to)
      (let ((message-deletable-headers (if (message-news-p)
					   nil
					 message-deletable-headers))
	    (mail-header-separator (if article-editing
				       ""
				     mail-header-separator)))
	(message-generate-headers
	 (copy-sequence (if (message-news-p)
			    message-required-news-headers
			  message-required-mail-headers)))
	(unless article-editing
	  (if (re-search-forward
	       (concat "^" (regexp-quote mail-header-separator) "\n") nil t)
	      (replace-match "\n"))
	  (setq mail-header-separator ""))
	(message-sort-headers)
	(mml-to-mime))
      (if raw
	  (let ((s (buffer-string)))
	    ;; Insert the content into unibyte buffer.
	    (erase-buffer)
	    (mm-disable-multibyte)
	    (insert s))
	(let ((gnus-newsgroup-charset (car message-posting-charset))
	      gnus-article-prepare-hook gnus-original-article-buffer
	      gnus-displaying-mime)
	  (run-hooks 'gnus-article-decode-hook)
	  (let ((gnus-newsgroup-name "dummy")
		(gnus-newsrc-hashtb (or gnus-newsrc-hashtb
					(gnus-make-hashtable 5))))
	    (gnus-article-prepare-display))))
      ;; Disable article-mode-map.
      (use-local-map nil)
      (add-hook 'kill-buffer-hook
		(lambda ()
		  (mm-destroy-parts gnus-article-mime-handles))
		nil t)
      (setq buffer-read-only t)
      (local-set-key "q" (lambda () (interactive) (kill-buffer nil)))
      (local-set-key "=" (lambda () (interactive) (delete-other-windows)))
      (local-set-key "\r"
		     (lambda ()
		       (interactive)
		       (widget-button-press (point))))
      (local-set-key [mouse-2]
		     (lambda (event)
		       (interactive "@e")
		       (widget-button-press (widget-event-point event) event)))
      ;; FIXME: Buffer is in article mode, but most tool bar commands won't
      ;; work.  Maybe only keep the following icons: search, print, quit
      (goto-char (point-min))))
  (if (and (not (special-display-p (buffer-name mml-preview-buffer)))
	   (boundp 'gnus-buffer-configuration)
	   (assq 'mml-preview gnus-buffer-configuration))
      (let ((gnus-message-buffer (current-buffer)))
	(gnus-configure-windows 'mml-preview))
    (pop-to-buffer mml-preview-buffer)))

(defun mml-validate ()
  "Validate the current MML document."
  (interactive)
  (mml-parse))

(defun mml-tweak-part (cont)
  "Tweak a MML part."
  (let ((tweak (cdr (assq 'tweak cont)))
	func)
    (cond
     (tweak
      (setq func
	    (or (cdr (assoc tweak mml-tweak-function-alist))
		(intern tweak))))
     (mml-tweak-type-alist
      (let ((alist mml-tweak-type-alist)
	    (type (or (cdr (assq 'type cont)) "text/plain")))
	(while alist
	  (if (string-match (caar alist) type)
	      (setq func (cdar alist)
		    alist nil)
	    (setq alist (cdr alist)))))))
    (if func
	(funcall func cont)
      cont)
    (let ((alist mml-tweak-sexp-alist))
      (while alist
	(if (eval (caar alist) t)
	    (funcall (cdar alist) cont))
	(setq alist (cdr alist)))))
  cont)

(defun mml-tweak-externalize-attachments (cont)
  "Tweak attached files as external parts."
  (let (filename-cons)
    (when (and (eq (car cont) 'part)
	       (not (cdr (assq 'buffer cont)))
	       (and (setq filename-cons (assq 'filename cont))
		    (not (equal (cdr (assq 'nofile cont)) "yes"))))
      (setcar cont 'external)
      (setcar filename-cons 'name))))

(provide 'mml)

;;; mml.el ends here
