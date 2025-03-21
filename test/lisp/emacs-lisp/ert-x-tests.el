;;; ert-x-tests.el --- Tests for ert-x.el  -*- lexical-binding:t -*-

;; Copyright (C) 2008, 2010-2025 Free Software Foundation, Inc.

;; Author: Phil Hagelberg
;; 	   Christian Ohler <ohler@gnu.org>

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

;; This file is part of ERT, the Emacs Lisp Regression Testing tool.
;; See ert.el or the texinfo manual for more details.

;;; Code:

(eval-when-compile
  (require 'cl-lib))
(require 'ert)
(require 'ert-x)

;;; Utilities

(ert-deftest ert-test-buffer-string-reindented ()
  (ert-with-test-buffer (:name "well-indented")
    (insert (concat "(hello (world\n"
                    "        'elisp)\n"))
    (emacs-lisp-mode)
    (should (equal (ert-buffer-string-reindented) (buffer-string))))
  (ert-with-test-buffer (:name "badly-indented")
    (insert (concat "(hello\n"
                    "       world)"))
    (emacs-lisp-mode)
    (should-not (equal (ert-buffer-string-reindented) (buffer-string)))))

(ert-deftest ert-filter-string ()
  (should (equal (ert-filter-string "foo bar baz" "quux")
                 "foo bar baz"))
  (should (equal (ert-filter-string "foo bar baz" "bar")
                 "foo  baz")))

(ert-deftest ert-propertized-string ()
  (should (equal-including-properties
           (ert-propertized-string "a" '(a b) "b" '(c t) "cd")
           #("abcd" 1 2 (a b) 2 4 (c t))))
  (should (equal-including-properties
           (ert-propertized-string "foo " '(face italic) "bar" " baz" nil
                                   " quux")
           #("foo bar baz quux" 4 11 (face italic)))))


;;; Tests for ERT itself that require test features from ert-x.el.

(ert-deftest ert-test-run-tests-interactively-2 ()
  :tags '(:causes-redisplay)
  (cl-letf* ((passing-test (make-ert-test
                            :name 'passing-test
                            :body (lambda () (ert-pass))))
             (failing-test (make-ert-test
                            :name 'failing-test
                            :body (lambda ()
                                    (ert-info ((propertize "foo\nbar"
                                                           'a 'b))
                                              (ert-fail
                                               "failure message")))))
             (skipped-test (make-ert-test
                            :name 'skipped-test
                            :body (lambda () (ert-skip
					      "skip message"))))
             (ert-debug-on-error nil)
             (messages nil)
             (buffer-name (generate-new-buffer-name "*ert-test-run-tests*"))
             ((symbol-function 'message)
              (lambda (format-string &rest args)
                (push (apply #'format format-string args) messages)))
             (ert--output-buffer-name buffer-name))
    (cl-flet ((expected-string (with-font-lock-p)
                (ert-propertized-string
                 "Selector: (member <passing-test> <failing-test> "
		 "<skipped-test>)\n"
                 "Passed:  1\n"
                 "Failed:  1 (1 unexpected)\n"
                 "Skipped: 1\n"
                 "Total:   3/3\n\n"
                 "Started at:\n"
                 "Finished.\n"
                 "Finished at:\n\n"
                 `(category ,(button-category-symbol
                              'ert--results-progress-bar-button)
                            button (t)
                            face ,(if with-font-lock-p
                                      'ert-test-result-unexpected
                                    'button))
                 ".Fs" nil "\n\n"
                 `(category ,(button-category-symbol
                              'ert--results-expand-collapse-button)
                            button (t)
                            face ,(if with-font-lock-p
                                      'ert-test-result-unexpected
                                    'button))
                 "F" nil " "
                 `(category ,(button-category-symbol
                              'ert--test-name-button)
                            button (t)
                            ert-test-name failing-test)
                 "failing-test"
                 nil "\n    Info: " '(a b) "foo\n"
                 nil "          " '(a b) "bar"
                 nil "\n    (ert-test-failed \"failure message\")\n\n\n")))
      (save-window-excursion
        (unwind-protect
            (let ((case-fold-search nil))
              (ert-run-tests-interactively
               `(member ,passing-test ,failing-test ,skipped-test))
              (should (equal messages `(,(concat
                                          "Ran 3 tests, 1 results were "
                                          "as expected, 1 unexpected, "
					  "1 skipped"))))
              (with-current-buffer buffer-name
                (font-lock-mode 0)
                (should (equal-including-properties
                         (ert-filter-string (buffer-string)
                                            '("Started at:\\(.*\\)$" 1)
                                            '("Finished at:\\(.*\\)$" 1))
                         (expected-string nil)))
                ;; `font-lock-mode' only works if interactive, so
                ;; pretend we are.
                (let ((noninteractive nil))
                  (font-lock-mode 1))
                (should (equal-including-properties
                         (ert-filter-string (buffer-string)
                                            '("Started at:\\(.*\\)$" 1)
                                            '("Finished at:\\(.*\\)$" 1))
                         (expected-string t)))))
          (when (get-buffer buffer-name)
            (kill-buffer buffer-name)))))))

(ert-deftest ert-test-describe-test ()
  "Tests `ert-describe-test'."
  (save-window-excursion
    (ert-with-buffer-renamed ("*Help*")
      (ert-describe-test 'ert-test-describe-test)
      (with-current-buffer "*Help*"
        (let ((case-fold-search nil))
          (should (string-match (concat
                                 "\\`ert-test-describe-test is a test"
                                 " defined in"
                                 " ['`‘]ert-x-tests.elc?['’]\\.\n\n"
                                 "Tests ['`‘]ert-describe-test['’]\\.\n\\'")
                                (buffer-string))))))))

(ert-deftest ert-test-message-log-truncation ()
  :tags '(:causes-redisplay)
  (let ((test (make-ert-test
               :body (lambda ()
                       ;; Emacs would combine messages if we
                       ;; generate the same message multiple
                       ;; times.
                       (message "a")
                       (message "b")
                       (message "c")
                       (message "d")))))
    (let (result)
      (ert-with-buffer-renamed ("*Messages*")
        (let ((message-log-max 2))
          (setq result (ert-run-test test)))
        (should (equal (with-current-buffer "*Messages*"
                         (buffer-string))
                       "c\nd\n")))
      (should (equal (ert-test-result-messages result) "a\nb\nc\nd\n")))))

(ert-deftest ert-test-builtin-message-log-flushing ()
  "This test attempts to demonstrate that there is no way to
force immediate truncation of the *Messages* buffer from Lisp
\(and hence justifies the existence of
`ert--force-message-log-buffer-truncation'): The only way that
came to my mind was \(message \"\"), which doesn't have the
desired effect."
  :tags '(:causes-redisplay)
  (ert-with-buffer-renamed ("*Messages*")
    (with-current-buffer "*Messages*"
      (should (equal (buffer-string) ""))
      ;; We used to get sporadic failures in this test that involved
      ;; a spurious newline at the beginning of the buffer, before
      ;; the first message.  Below, we print a message and erase the
      ;; buffer since this seems to eliminate the sporadic failures.
      (message "foo")
      (erase-buffer)
      (should (equal (buffer-string) ""))
      (let ((message-log-max 2))
        (let ((message-log-max t))
          (cl-loop for i below 4 do
                   (message "%s" i))
          (should (equal (buffer-string) "0\n1\n2\n3\n")))
        (should (equal (buffer-string) "0\n1\n2\n3\n"))
        (message "")
        (should (equal (buffer-string) "0\n1\n2\n3\n"))
        (message "Test message")
        (should (equal (buffer-string) "3\nTest message\n"))))))

(ert-deftest ert-test-force-message-log-buffer-truncation ()
  :tags '(:causes-redisplay)
  (cl-labels ((body ()
                (cl-loop for i below 3 do
                         (message "%s" i)))
              ;; Uses the implicit messages buffer truncation implemented
              ;; in Emacs's C core.
              (c (x)
                (ert-with-buffer-renamed ("*Messages*")
                  (let ((message-log-max x))
                    (body))
                  (with-current-buffer "*Messages*"
                    (buffer-string))))
              ;; Uses our lisp reimplementation.
              (lisp (x)
                (ert-with-buffer-renamed ("*Messages*")
                  (let ((message-log-max t))
                    (body))
                  (let ((message-log-max x))
                    (ert--force-message-log-buffer-truncation))
                  (with-current-buffer "*Messages*"
                    (buffer-string)))))
    (cl-loop for x in '(0 1 2 3 4 t) do
             (should (equal (c x) (lisp x))))))

(ert-deftest ert-x-tests--with-temp-file-generate-suffix ()
  (should (equal (ert--with-temp-file-generate-suffix "foo.el") "-foo"))
  (should (equal (ert--with-temp-file-generate-suffix "foo-test.el") "-foo"))
  (should (equal (ert--with-temp-file-generate-suffix "foo-tests.el") "-foo"))
  (should (equal (ert--with-temp-file-generate-suffix "foo-bar-baz.el")
                 "-foo-bar-baz"))
  (should (equal (ert--with-temp-file-generate-suffix "/foo/bar/baz.el")
                 "-baz")))

(ert-deftest ert-x-tests-with-temp-file ()
  (let (saved)
    (ert-with-temp-file fil
      (setq saved fil)
      (should (file-exists-p fil))
      (should (file-regular-p fil)))
    (should-not (file-exists-p saved))))

(ert-deftest ert-x-tests-with-temp-file/handle-error ()
  (let (saved)
    (ignore-errors
      (ert-with-temp-file fil
        (setq saved fil)
        (error "foo")))
    (should-not (file-exists-p saved))))

(ert-deftest ert-x-tests-with-temp-file/prefix-and-suffix-kwarg ()
  (ert-with-temp-file fil
    :prefix "foo"
    :suffix "bar"
    (should (string-match "foo.*bar" fil))))

(ert-deftest ert-x-tests-with-temp-file/text-kwarg ()
  (ert-with-temp-file fil
    :text "foobar3"
    (let ((buf (find-file-noselect fil)))
      (unwind-protect
          (with-current-buffer buf
            (should (equal (buffer-string) "foobar3")))
        (kill-buffer buf)))))

(ert-deftest ert-x-tests-with-temp-file/unknown-kwarg-signals-error ()
  (should-error
   (ert-with-temp-file fil :foo "foo" nil)))

(ert-deftest ert-x-tests-with-temp-directory ()
  (let (saved)
    (ert-with-temp-directory dir
      (setq saved dir)
      (should (file-exists-p dir))
      (should (file-directory-p dir))
      (should (equal dir (file-name-as-directory dir))))
    (should-not (file-exists-p saved))))

(ert-deftest ert-x-tests-with-temp-directory/text-signals-error ()
  (should-error
   (ert-with-temp-directory dir :text "foo" nil)))

(provide 'ert-x-tests)

;;; ert-x-tests.el ends here
