;;; url-expand.el --- expand-file-name for URLs -*- lexical-binding: t -*-

;; Copyright (C) 1999, 2004-2025 Free Software Foundation, Inc.

;; Keywords: comm, data, processes

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

(require 'url-methods)
(require 'url-util)
(require 'url-parse)

(defun url-expander-remove-relative-links (name)
  (if (equal name "")
      ;; An empty name is a properly valid relative URL reference/path.
      ""
    ;; Strip . and .. from pathnames
    (let ((new (if (not (string-match "^/" name))
                   (concat "/" name)
                 name)))

      ;; If it ends with a '/.' or '/..', tack on a trailing '/' sot hat
      ;; the tests that follow are not too complicated in terms of
      ;; looking for '..' or '../', etc.
      (if (string-match "/\\.+$" new)
          (setq new (concat new "/")))

      ;; Remove '/./' first
      (while (string-match "/\\(\\./\\)" new)
        (setq new (concat (substring new 0 (match-beginning 1))
                          (substring new (match-end 1)))))

      ;; Then remove '/../'
      (while (string-match "/\\([^/]*/\\.\\./\\)" new)
        (setq new (concat (substring new 0 (match-beginning 1))
                          (substring new (match-end 1)))))

      ;; Remove cruft at the beginning of the string, so people that put
      ;; in extraneous '..' because they are morons won't lose.
      (while (string-match "^/\\.\\.\\(/\\)" new)
        (setq new (substring new (match-beginning 1) nil)))
      new)))

(defun url-expand-file-name (url &optional default)
  "Convert URL to a fully specified URL, and canonicalize it.
Second arg DEFAULT is a URL to start with if URL is relative.
If DEFAULT is nil or missing, the current buffer's URL is used.
Path components that are `.' are removed, and
path components followed by `..' are removed, along with the `..' itself."
  (if (and url (not (string-match "^#" url)))
      ;; Need to nuke newlines and spaces in the URL, or we open
      ;; ourselves up to potential security holes.
      (setq url (mapconcat (lambda (x)
                             (if (memq x '(?\s ?\n ?\r))
                                 ""
                               (char-to-string x)))
			   url "")))

  ;; Need to figure out how/where to expand the fragment relative to
  (setq default (cond
		 ((url-p default)
		  ;; Default URL has already been parsed
		  default)
		 (default
		   ;; They gave us a default URL in non-parsed format
		   (url-generic-parse-url default))
		 (url-current-object
		  ;; We are in a URL-based buffer, use the pre-parsed object
		  url-current-object)
		 ((string-match url-nonrelative-link url)
		  ;; The URL they gave us is absolute, go for it.
		  nil)
		 (t
		  ;; Hmmm - this shouldn't ever happen.
		  (error "url-expand-file-name confused - no default?"))))

  (cond
   ((= (length url) 0)			; nil or empty string
    (url-recreate-url default))
   ((string-match url-nonrelative-link url) ; Fully-qualified URL,
                                            ; return it immediately
    url)
   (t
    (let* ((urlobj (url-generic-parse-url url))
	   (inhibit-file-name-handlers t)
	   (expander (if (url-type default)
                         (url-scheme-get-property (url-type default)
                                                  'expand-file-name)
                       ;; If neither the default nor the URL to be
                       ;; expanded have a protocol, then just use the
                       ;; identity expander as a fallback.
                       'url-identity-expander)))
      (if (string-match "^//" url)
	  (setq urlobj (url-generic-parse-url (concat (url-type default) ":"
						      url))))
      (funcall expander urlobj default)
      (url-recreate-url urlobj)))))

(defun url-identity-expander (urlobj defobj)
  (setf (url-type urlobj) (or (url-type urlobj) (url-type defobj))))

(defun url-default-expander (urlobj defobj)
  ;; The default expansion routine - urlobj is modified by side effect!
  (if (url-type urlobj)
      ;; Well, they told us the scheme, let's just go with it.
      nil
    (setf (url-type urlobj) (or (url-type urlobj) (url-type defobj)))
    (setf (url-portspec urlobj) (or (url-portspec urlobj)
                                (and (string= (url-type urlobj)
                                              (url-type defobj))
				     (url-port defobj))))
    (if (not (string= "file" (url-type urlobj)))
	(setf (url-host urlobj) (or (url-host urlobj) (url-host defobj))))
    (if (string= "ftp"  (url-type urlobj))
	(setf (url-user urlobj) (or (url-user urlobj) (url-user defobj))))
    ;; If the object we're expanding from is full, then we are now
    ;; full.
    (unless (url-fullness urlobj)
      (setf (url-fullness urlobj) (url-fullness defobj)))
    (let* ((pathandquery (url-path-and-query urlobj))
           (defpathandquery (url-path-and-query defobj))
           (file (car pathandquery))
           (query (or (cdr pathandquery) (and (equal file "") (cdr defpathandquery)))))
      (if (string-match "^/" (url-filename urlobj))
          (setq file (url-expander-remove-relative-links file))
	;; We use concat rather than expand-file-name to combine
	;; directory and file name, since urls do not follow the same
	;; rules as local files on all platforms.
        (setq file (url-expander-remove-relative-links
                    (if (equal file "")
                        (or (car (url-path-and-query defobj)) "")
                      (concat (url-file-directory (url-filename defobj)) file)))))
      (setf (url-filename urlobj) (if query (concat file "?" query) file)))))

(provide 'url-expand)

;;; url-expand.el ends here
