;;; ivy-make.el --- Select a Makefile target with ivy

;; Copyright (C) 2014-2019 Oleh Krehel

;; Author: Oleh Krehel <ohwoeowho@gmail.com>
;; URL: https://github.com/abo-abo/helm-make
;; Version: 0.2.0
;; Keywords: makefile

;; This file is not part of GNU Emacs

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; A call to `ivy-make' will give you a `ivy' selection of this directory
;; Makefile's targets.  Selecting a target will call `compile' on it.

;;; Code:

(require 'subr-x)

(declare-function helm "ext:helm")
(declare-function helm-marked-candidates "ext:helm")
(declare-function helm-build-sync-source "ext:helm")
(declare-function ivy-read "ext:ivy")
(declare-function projectile-project-root "ext:projectile")

(defgroup ivy-make nil
  "Select a Makefile target with helm."
  :group 'convenience)

(defcustom ivy-make-do-save nil
  "If t, save all open buffers visiting files from Makefile's directory."
  :type 'boolean
  :group 'ivy-make)

(defcustom ivy-make-build-dir ""
  "Specify a build directory for an out of source build.
The path should be relative to the project root.

When non-nil `ivy-make-projectile' will first look in that directory for a
makefile."
  :type '(string)
  :group 'ivy-make)
(make-variable-buffer-local 'ivy-make-build-dir)

(defcustom ivy-make-sort-targets nil
  "Whether targets shall be sorted.
If t, targets will be sorted as a final step before calling the
completion method.

HINT: If you are facing performance problems set this to nil.
This might be the case, if there are thousand of targets."
  :type 'boolean
  :group 'ivy-make)

(defcustom ivy-make-cache-targets nil
  "Whether to cache the targets or not.

If t, cache targets of Makefile. If `ivy-make' or `ivy-make-projectile'
gets called for the same Makefile again, and the Makefile hasn't changed
meanwhile, i.e. the modification time is `equal' to the cached one, reuse
the cached targets, instead of recomputing them. If nil do nothing.

You can reset the cache by calling `ivy-make-reset-db'."
  :type 'boolean
  :group 'ivy-make)

(defcustom ivy-make-executable "make"
  "Store the name of make executable."
  :type 'string
  :group 'ivy-make)

(defcustom ivy-make-ninja-executable "ninja"
  "Store the name of ninja executable."
  :type 'string
  :group 'ivy-make)

(defcustom ivy-make-niceness 0
  "When non-zero, run make jobs at this niceness level."
  :type 'integer
  :group 'ivy-make)

(defcustom ivy-make-arguments "-j%d"
  "Pass these arguments to `ivy-make-executable' or
`ivy-make-ninja-executable'. If `%d' is included, it will be substituted
 with the universal argument."
  :type 'string
  :group 'ivy-make)

(defcustom ivy-make-require-match t
  "When non-nil, don't allow selecting a target that's not on the list."
  :type 'boolean)

(defcustom ivy-make-named-buffer nil
  "When non-nil, name compilation buffer based on make target."
  :type 'boolean)

(defcustom ivy-make-comint nil
  "When non-nil, run ivy-make in Comint mode instead of Compilation mode."
  :type 'boolean)

(defcustom ivy-make-fuzzy-matching nil
  "When non-nil, enable fuzzy matching in helm make target(s) buffer."
  :type 'boolean)

(defcustom ivy-make-completion-method 'ivy
  "Method to select a candidate from a list of strings."
  :type '(choice
          (const :tag "Helm" helm)
          (const :tag "Ido" ido)
          (const :tag "Ivy" ivy)))

(defcustom ivy-make-nproc 1
  "Use that many processing units to compile the project.

If `0', automatically retrieve available number of processing units
using `ivy--make-get-nproc'.

Regardless of the value of this variable, it can be bypassed by
passing an universal prefix to `ivy-make' or `ivy-make-projectile'."
  :type 'integer)

(defvar ivy-make-command nil
  "Store the make command.")

(defvar ivy-make-target-history nil
  "Holds the recently used targets.")

(defvar ivy-make-makefile-names '("Makefile" "makefile" "GNUmakefile")
  "List of Makefile names which make recognizes.
An exception is \"GNUmakefile\", only GNU make understands it.")

(defvar ivy-make-ninja-filename "build.ninja"
  "Ninja build filename which ninja recognizes.")

(defun ivy--make-get-nproc ()
  "Retrieve available number of processing units on this machine.

If it fails to do so, `1' will be returned.
"
  (cond
    ((member system-type '(gnu gnu/linux gnu/kfreebsd cygwin))
     (if (executable-find "nproc")
         (string-to-number (string-trim (shell-command-to-string "nproc")))
       (warn "Can not retrieve available number of processing units, \"nproc\" not found")
       1))
    ;; What about the other systems '(darwin windows-nt aix berkeley-unix hpux usg-unix-v)?
    (t
     (warn "Retrieving available number of processing units not implemented for system-type %s" system-type)
     1)))

(defun ivy--make-action (target)
  "Make TARGET."
  (let* ((targets (and (eq ivy-make-completion-method 'helm)
                       (or (> (length (helm-marked-candidates)) 1)
                           ;; Give single marked candidate precedence over current selection.
                           (unless (equal (car (helm-marked-candidates)) target)
                             (setq target (car (helm-marked-candidates))) nil))
                       (mapconcat 'identity (helm-marked-candidates) " ")))
         (make-command (format ivy-make-command (or targets target)))
         (compile-buffer (compile make-command ivy-make-comint)))
    (when ivy-make-named-buffer
      (ivy--make-rename-buffer compile-buffer (or targets target)))))

(defun ivy--make-rename-buffer (buffer target)
  "Rename the compilation BUFFER based on the make TARGET."
  (let ((buffer-name (format "*compilation in %s (%s)*"
                             (abbreviate-file-name default-directory)
                             target)))
    (when (get-buffer buffer-name)
      (kill-buffer buffer-name))
    (with-current-buffer buffer
      (rename-buffer buffer-name))))

(defvar ivy--make-build-system nil
  "Will be 'ninja if the file name is `build.ninja',
and if the file exists 'make otherwise.")

(defun ivy--make-construct-command (arg file)
  "Construct the `ivy-make-command'.

ARG should be universal prefix value passed to `ivy-make' or
`ivy-make-projectile', and file is the path to the Makefile or the
ninja.build file."
  (format (concat "%s%s -C %s " ivy-make-arguments " %%s")
          (if (= ivy-make-niceness 0)
              ""
            (format "nice -n %d " ivy-make-niceness))
          (cond
            ((equal ivy--make-build-system 'ninja)
             ivy-make-ninja-executable)
            (t
             ivy-make-executable))
          (replace-regexp-in-string
           "^/\\(scp\\|ssh\\).+?:" ""
           (shell-quote-argument (file-name-directory file)))
          (let ((jobs (abs (if arg (prefix-numeric-value arg)
                             (if (= ivy-make-nproc 0) (ivy--make-get-nproc)
                               ivy-make-nproc)))))
            (if (> jobs 0) jobs 1))))

;;;###autoload
(defun ivy-make (&optional arg)
  "Call \"make -j ARG target\". Target is selected with completion."
  (interactive "P")
  (let ((makefile (ivy--make-makefile-exists default-directory)))
    (if (not makefile)
        (error "No build file in %s" default-directory)
      (setq ivy-make-command (ivy--make-construct-command arg makefile))
      (ivy--make makefile))))

(defconst ivy--make-ninja-target-regexp "^\\(.+\\): "
  "Regexp to identify targets in the output of \"ninja -t targets\".")

(defun ivy--make-target-list-ninja (makefile)
  "Return the target list for MAKEFILE by parsing the output of \"ninja -t targets\"."
  (let ((default-directory (file-name-directory (expand-file-name makefile)))
        (ninja-exe ivy-make-ninja-executable) ; take a copy in case buffer-local
        targets)
    (with-temp-buffer
      (call-process ninja-exe nil t t "-f" (file-name-nondirectory makefile)
                    "-t" "targets" "all")
      (goto-char (point-min))
      (while (re-search-forward ivy--make-ninja-target-regexp nil t)
        (push (match-string 1) targets))
      targets)))

(defun ivy--make-target-list-qp (makefile)
  "Return the target list for MAKEFILE by parsing the output of \"make -nqp\"."
  (let ((default-directory (file-name-directory
                            (expand-file-name makefile)))
        targets target)
    (with-temp-buffer
      (insert
       (shell-command-to-string
        "make -nqp __BASH_MAKE_COMPLETION__=1 .DEFAULT 2>/dev/null"))
      (goto-char (point-min))
      (unless (re-search-forward "^# Files" nil t)
        (error "Unexpected \"make -nqp\" output"))
      (while (re-search-forward "^\\([^%$:#\n\t ]+\\):\\([^=]\\|$\\)" nil t)
        (setq target (match-string 1))
        (unless (or (save-excursion
		      (goto-char (match-beginning 0))
		      (forward-line -1)
		      (looking-at "^# Not a target:"))
                    (string-match "^\\([/a-zA-Z0-9_. -]+/\\)?\\." target))
          (push target targets))))
    targets))

(defun ivy--make-target-list-default (makefile)
  "Return the target list for MAKEFILE by parsing it."
  (let (targets)
    (with-temp-buffer
      (insert-file-contents makefile)
      (goto-char (point-min))
      (while (re-search-forward "^\\([^: \n]+\\):" nil t)
        (let ((str (match-string 1)))
          (unless (string-match "^\\." str)
            (push str targets)))))
    (nreverse targets)))

(defcustom ivy-make-list-target-method 'default
  "Method of obtaining the list of Makefile targets.

For ninja build files there exists only one method of obtaining the list of
targets, and hence no `defcustom'."
  :type '(choice
          (const :tag "Default" default)
          (const :tag "make -qp" qp)))

(defun ivy--make-makefile-exists (base-dir &optional dir-list)
  "Check if one of `ivy-make-makefile-names' and `ivy-make-ninja-filename'
 exist in BASE-DIR.

Returns the absolute filename to the Makefile, if one exists,
otherwise nil.

If DIR-LIST is non-nil, also search for `ivy-make-makefile-names' and
`ivy-make-ninja-filename'."
  (let* ((default-directory (file-truename base-dir))
         (makefiles
          (progn
            (unless (and dir-list (listp dir-list))
              (setq dir-list (list "")))
            (let (result)
              (dolist (dir dir-list)
                (dolist (makefile `(,@ivy-make-makefile-names ,ivy-make-ninja-filename))
                  (push (expand-file-name makefile dir) result)))
              (reverse result))))
         (makefile (cl-find-if 'file-exists-p makefiles)))
    (when makefile
      (cond
        ((string-match "build\.ninja$" makefile)
         (setq ivy--make-build-system 'ninja))
        (t
         (setq ivy--make-build-system 'make))))
    makefile))

(defvar ivy-make-db (make-hash-table :test 'equal)
  "An alist of Makefile and corresponding targets.")

(cl-defstruct ivy-make-dbfile
  targets
  modtime
  sorted)

(defun ivy--make-cached-targets (makefile)
  "Return cached targets of MAKEFILE.

If there are no cached targets for MAKEFILE, the MAKEFILE modification
time has changed, or `ivy-make-cache-targets' is nil, parse the MAKEFILE,
and cache targets of MAKEFILE, if `ivy-make-cache-targets' is t."
  (let* ((att (file-attributes makefile 'integer))
         (modtime (if att (nth 5 att) nil))
         (entry (gethash makefile ivy-make-db nil))
         (new-entry (make-ivy-make-dbfile))
         (targets (cond
                    ((and ivy-make-cache-targets
                          entry
                          (equal modtime (ivy-make-dbfile-modtime entry))
                          (ivy-make-dbfile-targets entry))
                     (ivy-make-dbfile-targets entry))
                    (t
                     (delete-dups
                      (cond
                        ((equal ivy--make-build-system 'ninja)
                         (ivy--make-target-list-ninja makefile))
                        ((equal ivy-make-list-target-method 'qp)
                         (ivy--make-target-list-qp makefile))
                        (t
                         (ivy--make-target-list-default makefile))))))))
    (when ivy-make-sort-targets
      (unless (and ivy-make-cache-targets
                   entry
                   (ivy-make-dbfile-sorted entry))
        (setq targets (sort targets 'string<)))
      (setf (ivy-make-dbfile-sorted new-entry) t))

    (when ivy-make-cache-targets
      (setf (ivy-make-dbfile-targets new-entry) targets
            (ivy-make-dbfile-modtime new-entry) modtime)
      (puthash makefile new-entry ivy-make-db))
    targets))

;;;###autoload
(defun ivy-make-reset-cache ()
  "Reset cache, see `ivy-make-cache-targets'."
  (interactive)
  (clrhash ivy-make-db))

(defun ivy--make (makefile)
  "Call make for MAKEFILE."
  (when ivy-make-do-save
    (let* ((regex (format "^%s" default-directory))
           (buffers
            (cl-remove-if-not
             (lambda (b)
               (let ((name (buffer-file-name b)))
                 (and name
                      (string-match regex (expand-file-name name)))))
             (buffer-list))))
      (mapc
       (lambda (b)
         (with-current-buffer b
           (save-buffer)))
       buffers)))
  (let ((targets (ivy--make-cached-targets makefile))
        (default-directory (file-name-directory makefile)))
    (delete-dups ivy-make-target-history)
    (cl-case ivy-make-completion-method
      (helm
       (helm :sources (helm-build-sync-source "Targets"
                        :candidates 'targets
                        :fuzzy-match ivy-make-fuzzy-matching
                        :action 'ivy--make-action)
             :history 'ivy-make-target-history
             :preselect (when ivy-make-target-history
                          (car ivy-make-target-history))))
      (ivy
       (unless (window-minibuffer-p)
         (ivy-read "Target: "
                   targets
                   :history 'ivy-make-target-history
                   :preselect (car ivy-make-target-history)
                   :action 'ivy--make-action
                   :require-match ivy-make-require-match)))
      (ido
       (let ((target (ido-completing-read
                      "Target: " targets
                      nil nil nil
                      'ivy-make-target-history)))
         (when target
           (ivy--make-action target)))))))

;;;###autoload
(defun ivy-make-projectile (&optional arg)
  "Call `ivy-make' for `projectile-project-root'.
ARG specifies the number of cores.

By default `ivy-make-projectile' will look in `projectile-project-root'
followed by `projectile-project-root'/build, for a makefile.

You can specify an additional directory to search for a makefile by
setting the buffer local variable `ivy-make-build-dir'."
  (interactive "P")
  (require 'projectile)
  (let ((makefile (ivy--make-makefile-exists
                   (projectile-project-root)
                   (if (and (stringp ivy-make-build-dir)
                            (not (string-match-p "\\`[ \t\n\r]*\\'" ivy-make-build-dir)))
                       `(,ivy-make-build-dir "" "build")
                     `(,@ivy-make-build-dir "" "build")))))
    (if (not makefile)
        (error "No build file found for project %s" (projectile-project-root))
      (setq ivy-make-command (ivy--make-construct-command arg makefile))
      (ivy--make makefile))))

(provide 'ivy-make)

;;; ivy-make.el ends here
