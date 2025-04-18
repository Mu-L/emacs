;;; nnrss.el --- interfacing with RSS  -*- lexical-binding: t; -*-

;; Copyright (C) 2001-2025 Free Software Foundation, Inc.

;; Author: Shenghuo Zhu <zsh@cs.rochester.edu>
;; Keywords: RSS

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

(eval-when-compile (require 'cl-lib))

(require 'gnus)
(require 'nnoo)
(require 'nnmail)
(require 'message)
(require 'mm-util)
(require 'gnus-util)
(require 'time-date)
(require 'rfc2231)
(require 'mm-url)
(require 'rfc2047)
(require 'iso8601)
(require 'mml)
(require 'xml)
(require 'dom)

(defgroup nnrss nil
  "RSS access for Gnus."
  :group 'gnus)

(nnoo-declare nnrss)

(defvoo nnrss-directory (nnheader-concat gnus-directory "rss/")
  "Where nnrss will save its files.")

(defvoo nnrss-ignore-article-fields '(slash:comments)
  "List of fields that should be ignored when comparing RSS articles.
Some RSS feeds update article fields during their lives, e.g. to
indicate the number of comments or the number of times the
articles have been seen.  However, if there is a difference
between the local article and the distant one, the latter is
considered to be new.  To avoid this and discard some fields, set
this variable to the list of fields to be ignored.")

;; (group max rss-url)
(defvoo nnrss-server-data nil)

;; (num timestamp url subject author date extra)
(defvoo nnrss-group-data nil)
(defvoo nnrss-group-max 0)
(defvoo nnrss-group-min 1)
(defvoo nnrss-group nil)
(defvoo nnrss-group-hashtb (make-hash-table :test 'equal))
(defvoo nnrss-status-string "")

(defconst nnrss-version "nnrss 1.0")
(make-obsolete-variable 'nnrss-version 'emacs-version "29.1")

(defvar nnrss-group-alist '()
  "List of RSS addresses.")

(defvar nnrss-use-local nil
  "If non-nil nnrss will read the feeds from local files in `nnrss-directory'.")

(defvar nnrss-description-field 'X-Gnus-Description
  "Field name used for DESCRIPTION.
To use the description in headers, put this name into `nnmail-extra-headers'.")

(defvar nnrss-url-field 'X-Gnus-Url
  "Field name used for URL.
To use the description in headers, put this name into `nnmail-extra-headers'.")

(defvar nnrss-content-function nil
  "A function which is called in `nnrss-request-article'.
The arguments are (ENTRY GROUP ARTICLE).
ENTRY is the record of the current headline.  GROUP is the group name.
ARTICLE is the article number of the current headline.")

(defcustom nnrss-file-coding-system mm-universal-coding-system
  "Coding system used when reading and writing files.
If you run Gnus with various versions of Emacsen, the value of this
variable should be the coding system that all those Emacsen support.
Note that you have to regenerate all the nnrss groups if you change
the value.  Moreover, you should be patient even if you are made to
read the same articles twice, that arises for the difference of the
versions of xml.el."
  :type 'coding-system)

(defvar nnrss-compatible-encoding-alist
  (delq nil (mapcar (lambda (elem)
		      (if (and (mm-coding-system-p (car elem))
			       (mm-coding-system-p (cdr elem)))
			  elem))
		    mm-charset-override-alist))
  "Alist of encodings and those supersets.
The cdr of each element is used to decode data if it is available when
the car is what the data specify as the encoding.  Or, the car is used
for decoding when the cdr that the data specify is not available.")

(nnoo-define-basics nnrss)

;;; Interface functions

(defsubst nnrss-format-string (string)
  (replace-regexp-in-string " *\n *" " " string))

(defun nnrss-decode-group-name (group)
  (if (and group (mm-coding-system-p 'utf-8))
      (setq group (decode-coding-string group 'utf-8))
    group))

(deffoo nnrss-retrieve-headers (articles &optional group server _fetch-old)
  (setq group (nnrss-decode-group-name group))
  (nnrss-possibly-change-group group server)
  (let (e)
    (with-current-buffer nntp-server-buffer
      (erase-buffer)
      (dolist (article articles)
	(if (setq e (assq article nnrss-group-data))
	    (insert (number-to-string (car e)) "\t" ;; number
		    ;; subject
		    (or (nth 3 e) "")
		    "\t"
		    ;; from
		    (or (nth 4 e) "(nobody)")
		    "\t"
		    ;; date
		    (or (nth 5 e) "")
		    "\t"
		    ;; id
		    (format "<%d@%s.nnrss>" (car e) group)
		    "\t"
		    ;; refs
		    "\t"
		    ;; chars
		    "-1" "\t"
		    ;; lines
		    "-1" "\t"
		    ;; Xref
		    "" "\t"
		    (if (and (nth 6 e)
			     (memq nnrss-description-field
				   nnmail-extra-headers))
			(concat (symbol-name nnrss-description-field)
				": "
				(nnrss-format-string (nth 6 e))
				"\t")
		      "")
		    (if (and (nth 2 e)
			     (memq nnrss-url-field
				   nnmail-extra-headers))
			(concat (symbol-name nnrss-url-field)
				": "
				(nnrss-format-string (nth 2 e))
				"\t")
		      "")
		    "\n")))))
  'nov)

(deffoo nnrss-request-group (group &optional server dont-check _info)
  (setq group (nnrss-decode-group-name group))
  (nnheader-message 6 "nnrss: Requesting %s..." group)
  (nnrss-possibly-change-group group server)
  (prog1
      (if dont-check
	  t
	(nnrss-check-group group server)
	(nnheader-report 'nnrss "Opened group %s" group)
	(nnheader-insert
	 "211 %d %d %d %s\n" nnrss-group-max nnrss-group-min nnrss-group-max
	 (prin1-to-string group)
	 t))
    (nnheader-message 6 "nnrss: Requesting %s...done" group)))

(deffoo nnrss-close-group (_group &optional _server)
  t)

(deffoo nnrss-request-article (article &optional group server buffer)
  (setq group (nnrss-decode-group-name group))
  (when (stringp article)
    (setq article (if (string-match "\\`<\\([0-9]+\\)@" article)
		      (string-to-number (match-string 1 article))
		    0)))
  (nnrss-possibly-change-group group server)
  (let ((e (assq article nnrss-group-data))
	(nntp-server-buffer (or buffer nntp-server-buffer))
	) ;; err post
    (when e
      (with-current-buffer nntp-server-buffer
	(erase-buffer)
	(if group
	    (insert "Newsgroups: " group "\n"))
	(if (nth 3 e)
	    (insert "Subject: " (nth 3 e) "\n"))
	(if (nth 4 e)
	    (insert "From: " (nth 4 e) "\n"))
	(if (nth 5 e)
	    (insert "Date: " (nnrss-format-string (nth 5 e)) "\n"))
	(let ((header (buffer-string))
	      (text (nth 6 e))
	      (link (nth 2 e))
	      (enclosure (nth 7 e))
	      (comments (nth 8 e))
	      (rfc2047-header-encoding-alist
	       (if (mm-coding-system-p 'utf-8)
		   (cons '("Newsgroups" . utf-8)
			 rfc2047-header-encoding-alist)
		 rfc2047-header-encoding-alist))
	      rfc2047-encode-encoded-words body) ;; fn
	  (when (or text link enclosure comments)
	    (insert "\n")
	    (insert "<#multipart type=alternative>\n"
		    "<#part type=\"text/plain\">\n")
	    (setq body (point))
	    (when text
	      (insert text)
	      (goto-char body)
	      (while (re-search-forward "\n+" nil t)
		(replace-match " "))
	      (goto-char body)
	      ;; See `nnrss-check-group', which inserts "<br /><br />".
	      (when (search-forward "<br /><br />" nil t)
		(if (eobp)
		    (replace-match "\n")
		  (replace-match "\n\n")))
	      (unless (eobp)
		(let ((fill-column (default-value 'fill-column))
		      (window (get-buffer-window nntp-server-buffer)))
		  (when window
		    (setq fill-column
			  (max 1 (/ (* (window-width window) 7) 8))))
		  (fill-region (point) (point-max))
		  (goto-char (point-max))
		  (unless (bolp)
		    (insert "\n"))))
	      (when (or link enclosure)
		(insert "\n")))
	    (when link
	      (insert link "\n"))
	    (when enclosure
	      (insert (car enclosure) " "
		      (nth 2 enclosure) " "
		      (nth 3 enclosure) "\n"))
	    (when comments
	      (insert comments "\n"))
	    (setq body (buffer-substring body (point)))
	    (insert "<#/part>\n"
		    "<#part type=\"text/html\">\n"
		    "<html><head></head><body>\n")
	    (when text
	      (insert text "\n"))
	    (when link
	      (insert "<p><a href=\"" link "\">link</a></p>\n"))
	    (when enclosure
	      (insert "<p><a href=\"" (car enclosure) "\">"
		      (cadr enclosure) "</a> " (nth 2 enclosure)
		      " " (nth 3 enclosure) "</p>\n"))
	    (when comments
	      (insert "<p><a href=\"" comments "\">comments</a></p>\n"))
	    (insert "</body></html>\n"
		    "<#/part>\n"
		    "<#/multipart>\n"))
	  (condition-case nil
	      ;; Allow `mml-to-mime' to generate MIME article without
	      ;; making inquiry to a user for unknown encoding.
	      (let ((mml-confirmation-set
		     (cons 'unknown-encoding mml-confirmation-set)))
		(mml-to-mime))
	    (error
	     (erase-buffer)
	     (insert header
		     "Content-Type: text/plain; charset=gnus-decoded\n"
		     "Content-Transfer-Encoding: 8bit\n\n"
		     body)
	     (nnheader-message
	      3 "Warning - there might be invalid characters"))))
	(goto-char (point-min))
	(search-forward "\n\n")
	(forward-line -1)
	(insert (format "Message-ID: <%d@%s.nnrss>\n"
			(car e)
			(let ((rfc2047-encoding-type 'mime)
			      rfc2047-encode-max-chars)
			  (rfc2047-encode-string
			   (replace-regexp-in-string "[\t\n ]+" "_" group)))))
	(when nnrss-content-function
	  (funcall nnrss-content-function e group article))))
    (cond
     ;; (err (nnheader-report 'nnrss err))
     ((not e)
      (nnheader-report 'nnrss "no such id: %d" article))
     (t
      (nnheader-report 'nnrss "article %s retrieved" (car e))
      ;; we return the article number.
      (cons nnrss-group (car e))))))

(deffoo nnrss-open-server (server &optional defs _connectionless)
  (nnrss-read-server-data server)
  (nnoo-change-server 'nnrss server defs)
  t)

(deffoo nnrss-request-expire-articles
    (articles group &optional server force)
  (setq group (nnrss-decode-group-name group))
  (nnrss-possibly-change-group group server)
  (let (e days not-expirable changed)
    (dolist (art articles)
      (if (and (setq e (assq art nnrss-group-data))
	       (nnmail-expired-article-p
		group
		(if (listp (setq days (nth 1 e))) days
		  (days-to-time (- days (time-to-days 0))))
		force))
	  (setq nnrss-group-data (delq e nnrss-group-data)
		changed t)
	(push art not-expirable)))
    (if changed
	(nnrss-save-group-data group server))
    not-expirable))

(deffoo nnrss-request-delete-group (group &optional _force server)
  (setq group (nnrss-decode-group-name group))
  (nnrss-possibly-change-group group server)
  (let (elem)
    ;; There may be two or more entries in `nnrss-group-alist' since
    ;; this function didn't delete them formerly.
    (while (setq elem (assoc-string group nnrss-group-alist))
      (setq nnrss-group-alist (delq elem nnrss-group-alist))))
  (setq nnrss-server-data
	(delq (assoc-string group nnrss-server-data) nnrss-server-data))
  (nnrss-save-server-data server)
  (ignore-errors
    (let ((file-name-coding-system nnmail-pathname-coding-system))
      (delete-file (nnrss-make-filename group server))))
  t)

(deffoo nnrss-request-list-newsgroups (&optional server)
  (nnrss-possibly-change-group nil server)
  (with-current-buffer nntp-server-buffer
    (erase-buffer)
    (dolist (elem nnrss-group-alist)
      (if (nth 2 elem)
	  (insert (car elem) "\t" (nth 2 elem) "\n"))))
  t)

(deffoo nnrss-retrieve-groups (groups &optional server)
  (dolist (group groups)
    (setq group (nnrss-decode-group-name group))
    (nnrss-possibly-change-group group server)
    (nnrss-check-group group server))
  (with-current-buffer nntp-server-buffer
    (erase-buffer)
    (dolist (group groups)
      (let ((elem (assoc-string group nnrss-server-data)))
	(insert (format "%S %s 1 y\n" group (or (cadr elem) 0)))))
    'active))

(nnoo-define-skeleton nnrss)

;;; Internal functions
(defun nnrss-get-encoding ()
  "Return an encoding attribute specified in the current xml contents.
If `nnrss-compatible-encoding-alist' specifies the compatible encoding,
it is used instead.  If the xml contents doesn't specify the encoding,
return `utf-8' which is the default encoding for xml if it is available,
otherwise return nil."
  (goto-char (point-min))
  (if (re-search-forward
       "<\\?[^>]*encoding=\\(?:\"\\([^\">]+\\)\"\\|'\\([^'>]+\\)'\\)"
       nil t)
      (let ((encoding (intern (downcase (or (match-string 1)
					    (match-string 2))))))
	(or
	 (mm-coding-system-p (cdr (assq encoding
					nnrss-compatible-encoding-alist)))
	 (mm-coding-system-p encoding)
	 (mm-coding-system-p (car (rassq encoding
					 nnrss-compatible-encoding-alist)))))
    (mm-coding-system-p 'utf-8)))

(declare-function libxml-parse-html-region "xml.c"
		  (start end &optional base-url discard-comments))
(defun nnrss-fetch (url &optional local)
  "Fetch URL and put it in the expected Lisp structure."
  (mm-with-unibyte-buffer
    ;;some versions of url.el need this to close the connection quickly
    (let (cs xmlform htmlform)
      ;; bit o' work necessary for w3 pre-cvs and post-cvs
      (if local
	  (let ((coding-system-for-read 'binary))
	    (insert-file-contents url))
	;; FIXME: shouldn't binding `coding-system-for-read' be moved
	;; to `mm-url-insert'?
	(let ((coding-system-for-read 'binary))
	  (condition-case err
	      (mm-url-insert url)
	    (error (if (or debug-on-quit debug-on-error)
		       (signal (car err) (cdr err))
		     (message "nnrss: Failed to fetch %s" url))))))
      (nnheader-remove-cr-followed-by-lf)
      ;; Decode text according to the encoding attribute.
      (when (setq cs (nnrss-get-encoding))
	(insert (prog1
		    (decode-coding-string (buffer-string) cs)
		  (erase-buffer)
		  (mm-enable-multibyte))))
      (goto-char (point-min))

      (condition-case err1
	  (setq xmlform (xml-parse-region (point-min) (point-max)))
	(error
	 (condition-case err2
	     (setq htmlform (libxml-parse-html-region (point-min) (point-max)))
	   (error
	    (message "\
nnrss: %s: Not valid XML %s and libxml-parse-html-region doesn't work %s"
		     url err1 err2)))))
      (if htmlform
	  htmlform
	xmlform))))

(defun nnrss-possibly-change-group (&optional group server)
  (when (and server
	     (not (nnrss-server-opened server)))
    (nnrss-open-server server))
  (when (and group (not (equal group nnrss-group)))
    (nnrss-read-group-data group server)
    (setq nnrss-group group)))

(autoload 'timezone-parse-date "timezone")

(defun nnrss-normalize-date (date)
  "Return a date string of DATE in the style of RFC 822 and its successors.
This function handles the ISO 8601 date format described in
URL `https://www.w3.org/TR/NOTE-datetime', and also the RFC 822 style
which RSS 2.0 allows."
  (let (case-fold-search vector year month day time zone given)
    (cond ((null date))			; do nothing for this case
	  ;; if the date is just digits (unix time stamp):
	  ((string-match "\\`[0-9]+\\'" date)
	   (setq given (time-convert (string-to-number date) t)))
	  ;; RFC 822
	  ((string-match " [0-9]+ " date)
	   (setq vector (timezone-parse-date date)
		 year (string-to-number (aref vector 0)))
	   (when (>= year 1969)
	     (setq month (string-to-number (aref vector 1))
		   day (string-to-number (aref vector 2)))
	     (unless (>= (length (setq time (aref vector 3))) 3)
	       (setq time "00:00:00"))
	     (when (and (setq zone (aref vector 4))
			(not (string-match "\\`[A-Z+-]" zone)))
	       (setq zone nil))))
	  ;; ISO 8601
	  ((iso8601-valid-p date)
	   (let ((decoded (decoded-time-set-defaults (iso8601-parse date))))
	     (setq year (decoded-time-year decoded)
		   month (decoded-time-month decoded)
		   day (decoded-time-day decoded)
		   time (format "%02d:%02d:%02d"
				(decoded-time-hour decoded)
				(decoded-time-minute decoded)
				(decoded-time-second decoded))
		   zone (if (equal (decoded-time-zone decoded) "Z")
			    0
			  (decoded-time-zone decoded))))))
    (if month
	(concat (let ((system-time-locale "C"))
		  (format-time-string "%a, %d %b %Y "
				      (encode-time 0 0 0 day month year)))
		time
		(if zone
		    (format-time-string " %z" nil zone)
		  ""))
      (message-make-date given))))

;;; data functions

(defun nnrss-read-server-data (server)
  (setq nnrss-server-data nil)
  (let ((file (nnrss-make-filename "nnrss" server))
	(file-name-coding-system nnmail-pathname-coding-system))
    (when (file-exists-p file)
      (load file nil t t))))

(defun nnrss-save-server-data (server)
  (gnus-make-directory nnrss-directory)
  (let ((coding-system-for-write nnrss-file-coding-system)
	(file-name-coding-system nnmail-pathname-coding-system))
    (with-temp-file (nnrss-make-filename "nnrss" server)
      (insert (format ";; -*- coding: %s; -*-\n"
		      nnrss-file-coding-system))
      (gnus-prin1 `(setq nnrss-group-alist ',nnrss-group-alist))
      (insert "\n")
      (gnus-prin1 `(setq nnrss-server-data ',nnrss-server-data)))))

(defun nnrss-read-group-data (group server)
  (setq nnrss-group-data nil)
  (if (hash-table-p nnrss-group-hashtb)
      (clrhash nnrss-group-hashtb)
    (setq nnrss-group-hashtb (make-hash-table :test 'equal)))
  (let ((pair (assoc-string group nnrss-server-data)))
    (setq nnrss-group-max (or (cadr pair) 0))
    (setq nnrss-group-min (+ nnrss-group-max 1)))
  (let ((file (nnrss-make-filename group server))
	(file-name-coding-system nnmail-pathname-coding-system))
    (when (file-exists-p file)
      (load file nil t t)
      (dolist (e nnrss-group-data)
	(puthash (nth 9 e) t nnrss-group-hashtb)
	(when (and (car e) (> nnrss-group-min (car e)))
	  (setq nnrss-group-min (car e)))
	(when (and (car e) (< nnrss-group-max (car e)))
	  (setq nnrss-group-max (car e)))))))

(defun nnrss-save-group-data (group server)
  (gnus-make-directory nnrss-directory)
  (let ((coding-system-for-write nnrss-file-coding-system)
	(file-name-coding-system nnmail-pathname-coding-system))
    (with-temp-file (nnrss-make-filename group server)
      (insert (format ";; -*- coding: %s; -*-\n"
		      nnrss-file-coding-system))
      (gnus-prin1 `(setq nnrss-group-data ',nnrss-group-data)))))

(defun nnrss-make-filename (name server)
  (expand-file-name
   (nnrss-translate-file-chars
    (concat name
	    (and server
		 (not (equal server ""))
		 "-")
	    server
	    ".el"))
   nnrss-directory))

(gnus-add-shutdown 'nnrss-close 'gnus)

(defun nnrss-close ()
  "Clear internal nnrss variables."
  (setq nnrss-group-data nil
	nnrss-server-data nil
	nnrss-group-hashtb nil
	nnrss-group-alist nil))

;;; URL interface

(defun nnrss-no-cache (_url)
  "")

(defun nnrss-insert (url)
  (condition-case err
      (mm-url-insert url)
    (error (if (or debug-on-quit debug-on-error)
	       (signal (car err) (cdr err))
	     (message "nnrss: Failed to fetch %s" url)))))

(defun nnrss-decode-entities-string (string)
  (if string
      (mm-with-multibyte-buffer
	(insert string)
	(mm-url-decode-entities-nbsp)
	(buffer-string))))

(defun nnrss-mime-encode-string (string)
  (mm-with-multibyte-buffer
    (insert string)
    (mm-url-decode-entities-nbsp)
    (goto-char (point-min))
    (while (re-search-forward "[\t\n ]+" nil t)
      (replace-match " "))
    (goto-char (point-min))
    (skip-chars-forward " ")
    (delete-region (point-min) (point))
    (goto-char (point-max))
    (skip-chars-forward " ")
    (delete-region (point) (point-max))
    (let ((rfc2047-encoding-type 'mime)
	  rfc2047-encode-max-chars)
      (rfc2047-encode-region (point-min) (point-max)))
    (goto-char (point-min))
    (while (search-forward "\n" nil t)
      (delete-char -1))
    (buffer-string)))

;;; Snarf functions
(defun nnrss-make-hash-index (item)
  (gnus-message 9 "nnrss: Making hash index of %s" (gnus-prin1-to-string item))
  (setq item (seq-remove
	      (lambda (field)
		(when (listp field)
		  (memq (car field) nnrss-ignore-article-fields)))
	      item))
  (md5 (gnus-prin1-to-string item)
       nil nil
       nnrss-file-coding-system))

(defun nnrss-check-group (group server)
  (let (file xml subject url extra changed author date feed-subject
	     enclosure comments rss-ns  content-ns dc-ns ;; rdf-ns
	     hash-index)
    (if (and nnrss-use-local
	     (file-exists-p (setq file (expand-file-name
					(nnrss-translate-file-chars
					 (concat group ".xml"))
					nnrss-directory))))
	(setq xml (nnrss-fetch file t))
      (setq url (or (nth 2 (assoc-string group nnrss-server-data))
		    (cadr (assoc-string group nnrss-group-alist))))
      (unless url
	(setq url
	      (cdr
	       (assoc 'href
		      (nnrss-discover-feed
		       (read-string
                        (format "URL to search for %s: " group) "https://")))))
	(let ((pair (assoc-string group nnrss-server-data)))
	  (if pair
	      (setcdr (cdr pair) (list url))
	    (push (list group nnrss-group-max url) nnrss-server-data)))
	(setq changed t))
      (setq xml (nnrss-fetch url)))
    (setq dc-ns (nnrss-get-namespace-prefix xml "http://purl.org/dc/elements/1.1/")
	  ;; rdf-ns (nnrss-get-namespace-prefix xml "http://www.w3.org/1999/02/22-rdf-syntax-ns#")
	  rss-ns (nnrss-get-namespace-prefix xml "http://purl.org/rss/1.0/")
	  content-ns (nnrss-get-namespace-prefix xml "http://purl.org/rss/1.0/modules/content/"))
    (dolist (item (nreverse (nnrss-find-el (intern (concat rss-ns "item")) xml)))
      (when (and (listp item)
		 (string= (concat rss-ns "item") (car item))
		 (progn (setq hash-index (nnrss-make-hash-index item))
			(not (gethash hash-index nnrss-group-hashtb))))
	(setq subject (nnrss-node-text rss-ns 'title item))
	(setq url (nnrss-decode-entities-string
		   (nnrss-node-text rss-ns 'link (cddr item))))
	(setq extra (or (nnrss-node-text content-ns 'encoded item)
			(nnrss-node-text rss-ns 'description item)))
	(if (setq feed-subject (nnrss-node-text dc-ns 'subject item))
	    (setq extra (concat feed-subject "<br /><br />" extra)))
	(setq author (or (nnrss-node-text rss-ns 'author item)
			 (nnrss-node-text dc-ns 'creator item)
			 (nnrss-node-text dc-ns 'contributor item)))
	(setq date (nnrss-normalize-date
		    (or (nnrss-node-text dc-ns 'date item)
			(nnrss-node-text rss-ns 'pubDate item))))
	(setq comments (nnrss-node-text rss-ns 'comments item))
	(when (setq enclosure (cadr (assq (intern (concat rss-ns "enclosure")) item)))
	  (let ((url (cdr (assq 'url enclosure)))
		(len (cdr (assq 'length enclosure)))
		(type (cdr (assq 'type enclosure)))
		(name))
	    (setq len
		  (if (and len (integerp (setq len (string-to-number len))))
		      ;; actually already in `ls-lisp-format-file-size' but
		      ;; probably not worth to require it for one function
		      (cl-do ((size (/ len 1.0) (/ size 1024.0))
			   (post-fixes (list "" "k" "M" "G" "T" "P" "E")
				       (cdr post-fixes)))
			  ((< size 1024)
			   (format "%.1f%s" size (car post-fixes))))
		    "0"))
	    (setq url (or url ""))
	    (setq name (if (string-match "/\\([^/]*\\)$" url)
			   (match-string 1 url)
			 "file"))
	    (setq type (or type ""))
	    (setq enclosure (list url name len type))))
	(push
	 (list
          (incf nnrss-group-max)
	  (current-time)
	  url
	  (and subject (nnrss-mime-encode-string subject))
	  (and author (nnrss-mime-encode-string author))
	  date
	  (and extra (nnrss-decode-entities-string extra))
	  enclosure
	  comments
	  hash-index)
	 nnrss-group-data)
	(puthash hash-index t nnrss-group-hashtb)
	(setq changed t))
      (setq extra nil))
    (when changed
      (nnrss-save-group-data group server)
      (let ((pair (assoc-string group nnrss-server-data)))
	(if pair
	    (setcar (cdr pair) nnrss-group-max)
	  (push (list group nnrss-group-max) nnrss-server-data)))
      (nnrss-save-server-data server))))

(declare-function gnus-group-make-rss-group "gnus-group" (&optional url))

(defun nnrss-opml-import (opml-file)
  "OPML subscriptions import.
Read the file and attempt to subscribe to each Feed in the file."
  (interactive "fImport file: ")
  (mapc
   (lambda (node)
     (let ((xmlurl (cdr (assq 'xmlUrl (cadr node)))))
       (when (and xmlurl
		  (not (string-match "\\`[\t ]*\\'" xmlurl))
		  (prog1
                      (y-or-n-p (format "Subscribe to %s?" xmlurl))
		    (message "")))
	 (condition-case err
	     (progn
	       (gnus-group-make-rss-group xmlurl)
	       (forward-line 1))
	   (error
	    (message
	     "Failed to subscribe to %s (%s); type any key to continue: "
	     xmlurl
	     (error-message-string err))
	    (let ((echo-keystrokes 0))
	      (read-char)))))))
   (nnrss-find-el 'outline
		  (mm-with-multibyte-buffer
		    (insert-file-contents opml-file)
		    (xml-parse-region (point-min) (point-max))))))

(defun nnrss-opml-export ()
  "OPML subscription export.
Export subscriptions to a buffer in OPML Format."
  (interactive)
  (with-current-buffer (gnus-get-buffer-create "*OPML Export*")
    (set-buffer-file-coding-system 'utf-8)
    (insert "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
	    "<!-- OPML generated by Emacs Gnus' nnrss.el -->\n"
	    "<opml version=\"1.1\">\n"
	    "  <head>\n"
	    "    <title>mySubscriptions</title>\n"
	    "    <dateCreated>" (format-time-string "%a, %d %b %Y %T %z")
	    "</dateCreated>\n"
	    "    <ownerEmail>" user-mail-address "</ownerEmail>\n"
	    "    <ownerName>" (user-full-name) "</ownerName>\n"
	    "  </head>\n"
	    "  <body>\n")
    (dolist (sub nnrss-group-alist)
      (insert "    <outline text=\"" (car sub)
	      "\" xmlUrl=\"" (cadr sub) "\"/>\n"))
    (insert "  </body>\n"
	    "</opml>\n"))
  (pop-to-buffer "*OPML Export*")
  (sgml-mode))

(defun nnrss-generate-download-script ()
  "Generate a download script in the current buffer.
It is useful when `(setq nnrss-use-local t)'."
  (interactive)
  (insert "#!/bin/sh\n")
  (insert "WGET=wget\n")
  (insert "RSSDIR='" (expand-file-name nnrss-directory) "'\n")
  (dolist (elem nnrss-server-data)
    (let ((url (or (nth 2 elem)
		   (cadr (assoc-string (car elem) nnrss-group-alist)))))
      (insert "$WGET -q -O \"$RSSDIR\"/'"
	      (nnrss-translate-file-chars (concat (car elem) ".xml"))
	      "' '" url "'\n"))))

(defun nnrss-translate-file-chars (name)
  (let ((nnheader-file-name-translation-alist
	 (append nnheader-file-name-translation-alist '((?' . ?_)))))
    (nnheader-translate-file-chars name)))

(defun nnrss-node-text (namespace local-name element)
  (let* ((node (assq (intern (concat namespace (symbol-name local-name)))
		     element))
	 (text (if (and node (listp node))
		   (nnrss-node-just-text node)
		 node))
	 (cleaned-text (if text
			   (string-replace
			    "\r\n" "\n"
			    (replace-regexp-in-string
			     "^[\000-\037\177]+\\|^ +\\| +$" ""
			     text)))))
    (if (string-equal "" cleaned-text)
	nil
      cleaned-text)))

(defun nnrss-node-just-text (node)
  (if (and node (listp node))
      (mapconcat #'nnrss-node-just-text (cddr node) " ")
    node))

(defun nnrss-find-el (tag data &optional found-list)
  "Find all the matching elements in the data.
Careful with this on large documents!"
  (when (consp data)
    (dolist (bit data)
      (when (car-safe bit)
	(when (equal tag (car bit))
	  ;; Old xml.el may return a list of string.
	  (when (and (consp (caddr bit))
		     (stringp (caaddr bit)))
	    (setcar (cddr bit) (caaddr bit)))
	  (setq found-list
		(append found-list
			(list bit))))
	(if (and (consp (car-safe (caddr bit)))
		 (not (stringp (caddr bit))))
	    (setq found-list
		  (append found-list
			  (nnrss-find-el
			   tag (caddr bit))))
	  (setq found-list
		(append found-list
			(nnrss-find-el
			 tag (cddr bit))))))))
  found-list)

(defun nnrss-rsslink-p (el)
  "Test if the element we are handed is an RSS autodiscovery link."
  (and (eq (car-safe el) 'link)
       (string-equal (cdr (assoc 'rel (cadr el))) "alternate")
       (or (string-equal (cdr (assoc 'type (cadr el)))
			 "application/rss+xml")
	   (string-equal (cdr (assoc 'type (cadr el))) "text/xml"))))

(defun nnrss-get-rsslinks (data)
  "Extract the <link> elements that are links to RSS from the parsed data."
  (delq nil (mapcar
	     (lambda (el)
	       (if (nnrss-rsslink-p el) el))
	     (nnrss-find-el 'link data))))

(defun nnrss-extract-hrefs (data)
  "Recursively extract hrefs from a page's source.
DATA should be the output of `xml-parse-region'."
  (mapcar (lambda (ahref)
	    (cdr (assoc 'href (cadr ahref))))
	  (nnrss-find-el 'a data)))

(defmacro nnrss-match-macro (base-uri item onsite-list offsite-list)
  `(cond ((or (string-match (concat "^" ,base-uri) ,item)
	      (not (string-search "://" ,item)))
	  (setq ,onsite-list (append ,onsite-list (list ,item))))
	 (t (setq ,offsite-list (append ,offsite-list (list ,item))))))

(defun nnrss-order-hrefs (base-uri hrefs)
  "Given a list of hrefs, sort them using the following priorities:
  1. links ending in .rss
  2. links ending in .rdf
  3. links ending in .xml
  4. links containing the above
  5. offsite links

BASE-URI is used to determine the location of the links and
whether they are `offsite' or `onsite'."
  (let (rss-onsite-end  rdf-onsite-end  xml-onsite-end
	rss-onsite-in   rdf-onsite-in   xml-onsite-in
	rss-offsite-end rdf-offsite-end xml-offsite-end
	rss-offsite-in rdf-offsite-in xml-offsite-in)
    (dolist (href hrefs)
      (cond ((null href))
	    ((string-match "\\.rss$" href)
	     (nnrss-match-macro
	      base-uri href rss-onsite-end rss-offsite-end))
	    ((string-match "\\.rdf$" href)
	     (nnrss-match-macro
	      base-uri href rdf-onsite-end rdf-offsite-end))
	    ((string-match "\\.xml$" href)
	     (nnrss-match-macro
	      base-uri href xml-onsite-end xml-offsite-end))
	    ((string-match "rss" href)
	     (nnrss-match-macro
	      base-uri href rss-onsite-in rss-offsite-in))
	    ((string-match "rdf" href)
	     (nnrss-match-macro
	      base-uri href rdf-onsite-in rdf-offsite-in))
	    ((string-match "xml" href)
	     (nnrss-match-macro
	      base-uri href xml-onsite-in xml-offsite-in))))
    (append
     rss-onsite-end  rdf-onsite-end  xml-onsite-end
     rss-onsite-in   rdf-onsite-in   xml-onsite-in
     rss-offsite-end rdf-offsite-end xml-offsite-end
     rss-offsite-in rdf-offsite-in xml-offsite-in)))

(defun nnrss-discover-feed (url)
  "Given a page, find an RSS feed.
Use Mark Pilgrim's `ultra-liberal rss locator'."
  (let ((parsed-page (nnrss-fetch url)))
    ;;    1. if this url is the rss, use it.
    (if (nnrss-rss-p parsed-page)
	(let ((rss-ns (nnrss-get-namespace-prefix parsed-page "http://purl.org/rss/1.0/")))
	  (nnrss-rss-title-description rss-ns parsed-page url))

      ;;    2. look for the <link rel="alternate"
      ;;    type="application/rss+xml" and use that if it is there.
      (let ((links (nnrss-get-rsslinks parsed-page)))
	(if links
	    (let* ((xml (nnrss-fetch
			 (cdr (assoc 'href (cadar links)))))
		   (rss-ns (nnrss-get-namespace-prefix
			    xml "http://purl.org/rss/1.0/")))
	      (nnrss-rss-title-description
	       rss-ns xml (cdr (assoc 'href (cadar links)))))

	  ;;    3. look for links on the site in the following order:
	  ;;       - onsite links ending in .rss, .rdf, or .xml
	  ;;       - onsite links containing any of the above
	  ;;       - offsite links ending in .rss, .rdf, or .xml
	  ;;       - offsite links containing any of the above
	  (let* ((base-uri (progn (string-match ".*://[^/]+/?" url)
				  (match-string 0 url)))
		 (hrefs (nnrss-order-hrefs
			 base-uri (nnrss-extract-hrefs parsed-page)))
		 (rss-link nil))
	    (while (and (eq rss-link nil) (not (eq hrefs nil)))
	      (let ((href-data (nnrss-fetch (car hrefs))))
		(if (nnrss-rss-p href-data)
		    (let* ((rss-ns (nnrss-get-namespace-prefix href-data "http://purl.org/rss/1.0/")))
		      (setq rss-link (nnrss-rss-title-description
				      rss-ns href-data (car hrefs))))
		  (setq hrefs (cdr hrefs)))))
            rss-link))))))

(defun nnrss-rss-p (data)
  "Test if DATA is an RSS feed.
Simply ensures that the first element is rss or rdf."
  (or (eq (caar data) 'rss)
      (eq (caar data) 'rdf:RDF)))

(defun nnrss-rss-title-description (rss-namespace data url)
  "Return the title of an RSS feed."
  (if (nnrss-rss-p data)
      (let ((description (intern (concat rss-namespace "description")))
	    (title (intern (concat rss-namespace "title")))
	    (channel (nnrss-find-el (intern (concat rss-namespace "channel"))
				    data)))
	(list
	 (cons 'description (caddr (nth 0 (nnrss-find-el description channel))))
	 (cons 'title (caddr (nth 0 (nnrss-find-el title channel))))
	 (cons 'href url)))))

(defun nnrss-get-namespace-prefix (el uri)
  "Given EL (containing a parsed element) and URI (containing a string
that gives the URI for which you want to retrieve the namespace
prefix), return the prefix."
  (let* ((dom (car el))
         (prefix (car (rassoc uri (dom-attributes
			           (dom-search
				    dom
				    (lambda (node)
				      (rassoc uri (dom-attributes node))))))))
	 (nslist (if prefix
		     (split-string (symbol-name prefix) ":")))
	 (ns (cond ((eq (length nslist) 1) ; no prefix given
		    "")
		   ((eq (length nslist) 2) ; extract prefix
		    (cadr nslist)))))
    (if (and ns (not (string= ns "")))
	(concat ns ":")
      ns)))

(defun nnrss-find-rss-via-syndic8 (_url)
  "This function is obsolete and does nothing.  Syndic8 shut down in 2013."
  (declare (obsolete nil "28.1"))
  nil)

(provide 'nnrss)

;;; nnrss.el ends here
