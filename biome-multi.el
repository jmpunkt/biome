;;; biome-multi.el --- Do multiple queries to Open Meteo  -*- lexical-binding: t -*-

;; Copyright (C) 2024 Korytov Pavel

;; Author: Korytov Pavel <thexcloud@gmail.com>
;; Maintainer: Korytov Pavel <thexcloud@gmail.com>

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Tools for doing multiple queries to Open Meteo.

;;; Code:
(require 'biome-query)
(require 'font-lock)
(require 'transient)

(defvar biome-multi-query-current nil
  "Current query.

This is a list of forms as defined by `biome-query-current'.")

(defvar biome-multi--callback nil
  "Call this with the selected query.")

(defclass biome-multi--transient-report (transient-suffix)
  ((transient :initform t))
  "A class to display the current report for `biome-multi'.")

(cl-defmethod transient-init-value ((_ biome-multi--transient-report))
  "A dummy method for `biome-multi--transient-report'."
  nil)

(cl-defmethod transient-format ((_ biome-multi--transient-report))
  "Format the current report for `biome-multi'."
  (if (seq-empty-p biome-multi-query-current)
      (propertize "Add at least one query" 'face 'error)
    (cl-loop for i from 0
             for query in biome-multi-query-current
             concat (propertize (format "Query #%d: %s\n" i
                                        (alist-get :name query))
                                'face 'font-lock-keyword-face)
             concat (biome-query--format query)
             if (not (eq i (1- (length biome-multi-query-current))))
             concat "\n")))

(transient-define-infix biome-multi--transient-report-infix ()
  :class 'biome-multi--transient-report
  :key "~~1")

(defun biome-multi-add-query ()
  "Add new query to `biome-multi'."
  (interactive)
  (funcall-interactively
   #'biome-query
   (lambda (query)
     (if (seq-empty-p biome-multi-query-current)
         (setq biome-multi-query-current (list (copy-tree query)))
       (nconc biome-multi-query-current (list (copy-tree query))))
     (biome-multi-query biome-multi--callback))))

(defun biome-multi-reset ()
  "Reset `biome-multi'."
  (interactive)
  (setq biome-multi-query-current nil))

(defun biome-multi-edit (idx)
  "Edit query number IDX in `biome-multi'."
  (interactive "nQuery number: ")
  (when (or (< idx 0)
            (>= idx (length biome-multi-query-current)))
    (user-error "Invalid query number"))
  (setq biome-query-current (nth idx biome-multi-query-current))
  (setq biome-query--callback
        (lambda (query)
          (setf (nth idx biome-multi-query-current) query)
          (biome-multi-query biome-multi--callback)))
  (biome-query--section-open (alist-get :name biome-query-current)))

(defun biome-multi-remove (idx)
  "Remove query number IDX from `biome-multi'."
  (interactive "nQuery number: ")
  (when (or (< idx 0)
            (>= idx (length biome-multi-query-current)))
    (user-error "Invalid query number"))
  (setq biome-multi-query-current
        (cl-loop for query in biome-multi-query-current
                 for i from 0
                 unless (eq i idx)
                 collect query)))

(defun biome-multi-exec ()
  "Process the query made by `biome-multi-query'."
  (interactive)
  (when (seq-empty-p biome-multi-query-current)
    (user-error "No queries to execute"))
  (funcall biome-multi--callback biome-multi-query-current))

(defun biome-multi--generate-preset ()
  "Generate a preset for the current multi-query."
  (interactive)
  (let ((buf (generate-new-buffer "*biome-preset*")))
    (with-current-buffer buf
      (emacs-lisp-mode)
      (insert ";; Add this to your config\n")
      (insert (pp-to-string `(biome-def-multi-preset ,(gensym "biome-query-preset-")
                               ,biome-multi-query-current))))
    (switch-to-buffer buf)))

(transient-define-prefix biome-multi-query (callback)
  ["Open Meteo Multi Query"
   (biome-multi--transient-report-infix)]
  ["Queries"
   :class transient-row
   ("a" "Add query" biome-multi-add-query :transient transient--do-stack)
   ("e" "Edit query" biome-multi-edit :transient transient--do-stack)
   ("d" "Delete query" biome-multi-remove :transient t)]
  ["Actions"
   :class transient-row
   ("RET" "Run" biome-multi-exec)
   ("P" "Generate preset definition" biome-multi--generate-preset)
   ("R" "Reset" biome-multi-reset :transient t)
   ("q" "Quit" transient-quit-one)]
  (interactive (list nil))
  (unless callback
    (error "Callback is not set.  Run M-x `biome-multi' instead"))
  (setq biome-multi--callback callback)
  (transient-setup 'biome-multi-query))

(defun biome-multi--unique-names-grouped (names-by-group group-names)
  "Make names unique in accordance with GROUP-NAMES.

NAMES-BY-GROUP is a list of lists of names.  GROUP-NAMES is a list
of group names.  The function returns a hash table mapping
original names to unique names."
  (let ((name-occurences (make-hash-table :test #'equal))
        (names-mapping (make-hash-table :test #'equal)))
    (cl-loop for names in names-by-group
             do (cl-loop for name in names
                         do (puthash name
                                     (1+ (gethash name name-occurences 0))
                                     name-occurences)))
    (cl-loop for names in names-by-group
             for group-name in group-names
             do (cl-loop
                 for name in names
                 for occurences = (gethash name name-occurences)
                 do (puthash (format "%s--%s" group-name name)
                             (if (= occurences 1)
                                 name
                               (format "%s_%s" name
                                       (replace-regexp-in-string
                                        (rx space) "_" (downcase group-name))))
                             names-mapping)))
    names-mapping))

(defun biome-multi--unique-names (names)
  "Make NAMES unique.

NAMES is a list of strings.  The return value is a list of
strings as well."
  (let ((name-occurences (make-hash-table :test #'equal))
        (added-occurences (make-hash-table :test #'equal)))
    (cl-loop for name in names
             do (puthash name
                         (1+ (gethash name name-occurences 0))
                         name-occurences))
    (cl-loop for name in names
             for occurences = (gethash name name-occurences)
             for added = (gethash name added-occurences)
             collect (if (= occurences 1)
                         name
                       (format "%s_%d" name
                               (puthash
                                name
                                (1+ (or added 0))
                                added-occurences))))))

(defun biome-multi--join-results (queries query-names vars-mapping results)
  "Join RESULTS of QUERIES by time.

Time has be in a string format, comparable by `string-lessp'.

QUERIES is a list of forms as defined by `biome-query-current'.
QUERY-NAMES is a list of query names, made unique.  VARS-MAPPING is
the result of `biome-multi--unique-names-grouped' on the list of
variables.  RESULTS is a list of responses from Open Meteo.

This function returns the results field mimicking the one returned
by Open Meteo."
  (let ((times (make-hash-table :test #'equal))
        (var-values-per-time (make-hash-table :test #'equal)))
    (cl-loop for result in results
             for query in queries
             for query-name in query-names
             for group-name = (alist-get :group query)
             for vars-field = (intern group-name)
             for times-vector = (thread-last
                                  result (alist-get vars-field) (alist-get 'time))
             do (cl-loop for time across times-vector
                         do (puthash time t times))
             do (cl-loop for (var-name . values) in (seq-filter
                                                     (lambda (v) (not (eq 'time (car v))))
                                                     (alist-get vars-field result))
                         for mapped-var-name =
                         (gethash (format "%s--%s" query-name var-name) vars-mapping)
                         for var-values = (make-hash-table :test #'equal)
                         do (cl-loop for time across times-vector
                                     for value across values
                                     do (puthash time value var-values))
                         do (puthash mapped-var-name var-values var-values-per-time)))
    (let ((times-sorted (seq-sort #'string-lessp (hash-table-keys times))))
      `((time . ,(vconcat times-sorted))
        ,@(cl-loop for var-name being the hash-keys of var-values-per-time
                   using (hash-values var-values)
                   collect
                   (cons (intern var-name)
                         (vconcat
                          (cl-loop for time in times-sorted
                                   collect (gethash time var-values)))))))))

(defun biome-multi--merge (queries results)
  "Merge QUERIES into one query.

QUERIES is a list of forms as defined by `biome-query-current'.  RESULTS
is a list of responses from Open Meteo.

The function mimicks the response of Open Meteo, but only insofar
as it is necessary for `biome-grid'."
  (let* ((vars-by-group
          (cl-loop for query in queries
                   for group = (alist-get :group query)
                   collect (alist-get group (alist-get :params query)
                                      nil nil #'string-equal)))
         (query-names
          (biome-multi--unique-names
           (cl-loop for query in queries
                    collect (alist-get :name query))))
         (vars-mapping (biome-multi--unique-names-grouped vars-by-group query-names)))
    `(((:name . "Multi Query")
       (:group . "multi")
       (:params . (("multi" .
                    ,(cl-loop for var-name being the hash-values of vars-mapping
                              collect var-name)))))
      ((multi_units
        . ,(cons
            (cons 'time "iso8601")
            (cl-loop
             for result in results
             for query in queries
             for query-name in query-names
             for group-name = (alist-get :group query)
             for units-field = (intern (format "%s_units" group-name))
             append (cl-loop
                     for (var-name . unit) in (alist-get units-field result)
                     unless (equal var-name 'time)
                     collect (cons (intern
                                    (gethash (format "%s--%s" query-name var-name)
                                             vars-mapping))
                                   unit)))))
       (multi . ,(biome-multi--join-results queries query-names vars-mapping results))))))

(provide 'biome-multi)
;;; biome-multi.el ends here
