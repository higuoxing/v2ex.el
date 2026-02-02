;;; v2ex.el --- V2EX Client for Emacs  -*- lexical-binding: t; -*-

(require 'url)
(require 'json)
(require 'cl-lib)
(require 'subr-x)
(require 'shr)

;;; --- Configuration ---

(defgroup v2ex nil "V2EX client for Emacs." :group 'external)

(defcustom v2ex-api-base "https://www.v2ex.com/api" "Base URL for V2EX API." :type 'string :group 'v2ex)
(defcustom v2ex-token-file "~/.config/v2ex/token.txt" "Path to V2EX API v2 token." :type 'string :group 'v2ex)

;; Image Display Settings
(setq shr-inhibit-images nil)            ; Allow images to be displayed
(setq shr-max-image-proportion 0.7)      ; Max size relative to window
(setq shr-use-fonts t)                   ; Use nice fonts for rendering

(defcustom v2ex-column-width-node 16 "Width of Node column." :type 'integer :group 'v2ex)
(defcustom v2ex-column-width-title 60 "Width of Title column." :type 'integer :group 'v2ex)
(defcustom v2ex-column-width-author 14 "Width of Author column." :type 'integer :group 'v2ex)
(defcustom v2ex-column-width-replies 8 "Width of Replies column." :type 'integer :group 'v2ex)

;;; --- Variables ---

(defvar-local v2ex--current-topic-id nil "Topic ID of current buffer.")
(defvar-local v2ex--current-page 1 "Current page number.")
(defvar-local v2ex--current-node nil "Current node slug.")
(defvar-local v2ex--current-node-title nil "Current node display title.")
(defvar-local v2ex--all-topics nil "Stored topics for pagination.")

;;; --- Utilities ---

(defun v2ex--get-token ()
  "Read V2EX token."
  (let ((path (expand-file-name v2ex-token-file)))
    (if (file-exists-p path)
        (with-temp-buffer (insert-file-contents path) (string-trim (buffer-string)))
      (error "V2EX Token file not found: %s" path))))

(defun v2ex--truncate-string (str width)
  "Truncate STR to WIDTH."
  (if (> (string-width (or str "")) width)
      (concat (truncate-string-to-width str (- width 3)) "...")
    (or str "")))

(defun v2ex--clean-text (text)
  "Remove carriage returns."
  (if (stringp text) (replace-regexp-in-string "\r" "" text) ""))

(defun v2ex--render-html (html)
  "Render HTML string using shr with image support."
  (when (stringp html)
    (with-temp-buffer
      (insert html)
      (let ((shr-width (window-width (get-buffer-window (current-buffer)))))
        (shr-render-region (point-min) (point-max)))
      (buffer-string))))

;;; --- Modes ---

(define-derived-mode v2ex-mode tabulated-list-mode "V2EX"
  "Major mode for browsing V2EX topics list."
  (setq tabulated-list-format 
        (vector `("Node" ,v2ex-column-width-node t) `("Title" ,v2ex-column-width-title t)
                `("Author" ,v2ex-column-width-author t) `("Replies" ,v2ex-column-width-replies t)))
  (setq tabulated-list-padding 2)
  (define-key v2ex-mode-map (kbd "RET") #'v2ex--open-at-point)
  (define-key v2ex-mode-map (kbd "g") #'v2ex)
  (define-key v2ex-mode-map (kbd "m") #'v2ex-load-more)
  (tabulated-list-init-header))

(define-derived-mode v2ex-view-mode special-mode "V2EX-View"
  "Major mode for reading V2EX topics."
  (setq buffer-read-only t) (visual-line-mode 1)
  (define-key v2ex-view-mode-map (kbd "q") #'quit-window)
  (define-key v2ex-view-mode-map (kbd "l") (lambda () (interactive) (switch-to-buffer "*V2EX*")))
  (define-key v2ex-view-mode-map (kbd "g") #'v2ex--refresh-current-topic)
  (define-key v2ex-view-mode-map (kbd "n") #'v2ex--next-page)
  (define-key v2ex-view-mode-map (kbd "p") #'v2ex--prev-page)
  (define-key v2ex-view-mode-map (kbd "RET") #'v2ex--open-at-point))

;;; --- Network & Rendering ---

(defun v2ex--fetch-api (endpoint callback &optional use-v2)
  "Generic API requester."
  (let* ((token (when use-v2 (v2ex--get-token)))
         (url-request-method "GET")
         (url-request-extra-headers `(("User-Agent" . "Emacs-V2EX-Client/1.0")
                                      ,@(when token `(("Authorization" . ,(concat "Bearer " token)))))))
    (url-retrieve (concat v2ex-api-base endpoint)
                  (lambda (status cb)
                    (unwind-protect
                        (if (plist-get status :error)
                            (message "V2EX Error: %S" (plist-get status :error))
                          (goto-char (point-min))
                          (when (re-search-forward "\n\n" nil t)
                            (let ((json-object-type 'alist) (json-array-type 'list))
                              (funcall cb (json-read)))))
                      (kill-buffer (current-buffer))))
                  (list callback))))

(defun v2ex--render-list (data &optional append node-title-override)
  "Render topic list."
  (let* ((new-topics (if (alist-get 'result data) (alist-get 'result data) data))
         (buffer (get-buffer-create "*V2EX*")))
    (with-current-buffer buffer
      (v2ex-mode)
      (when node-title-override (setq v2ex--current-node-title node-title-override))
      (setq v2ex--all-topics (if append (append v2ex--all-topics new-topics) new-topics))
      (setq tabulated-list-entries
            (mapcar (lambda (topic)
                      (let* ((id (number-to-string (alist-get 'id topic)))
                             (node (alist-get 'node topic))
                             (disp-node (or (alist-get 'title node) v2ex--current-node-title "Latest"))
                             (node-name (or (alist-get 'name node) v2ex--current-node))
                             (member (alist-get 'member topic)))
                        (list id (vector (propertize (v2ex--truncate-string disp-node v2ex-column-width-node) 
                                                     'face 'font-lock-comment-face 'v2ex-node-name node-name)
                                         (propertize (v2ex--truncate-string (alist-get 'title topic) v2ex-column-width-title) 'face 'link)
                                         (propertize (v2ex--truncate-string (alist-get 'username member) v2ex-column-width-author) 
                                                     'face 'link 'v2ex-url (alist-get 'url member))
                                         (number-to-string (alist-get 'replies topic))))))
                    v2ex--all-topics))
      (when v2ex--current-node
        (setq tabulated-list-entries (append tabulated-list-entries 
                                             (list (list "more" (vector "----" "[ MORE TOPICS ]" "----" "----"))))))
      (tabulated-list-print t) (display-buffer buffer))))

(defun v2ex--render-topic-page (topic-data replies-data page)
  "Render topic page. Images will be loaded asynchronously."
  (let* ((topic (alist-get 'result topic-data))
         (replies (alist-get 'result replies-data))
         (pagination (alist-get 'pagination replies-data))
         (total-pages (or (alist-get 'pages pagination) 1))
         (member (alist-get 'member topic))
         (op-username (alist-get 'username member))
         (node (alist-get 'node topic))
         (buffer (get-buffer-create "*V2EX-Post*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer) (v2ex-view-mode)
        (setq-local v2ex--current-topic-id (number-to-string (alist-get 'id topic)))
        (setq-local v2ex--current-page page)
        (insert (propertize (v2ex--clean-text (alist-get 'title topic)) 'face '(:height 1.3 :weight bold :inherit header-line)) "\n\n")
        (insert (propertize "Author: " 'face 'font-lock-comment-face) (propertize op-username 'face 'link 'v2ex-url (alist-get 'url member)) "  ")
        (insert (propertize "Node: " 'face 'font-lock-comment-face) (propertize (alist-get 'title node) 'face 'link 'v2ex-node-name (alist-get 'name node)) "\n")
        (insert (propertize (make-string (window-width) ?─) 'face 'font-lock-comment-face) "\n\n")

        ;; Post Content
        (insert (v2ex--render-html (alist-get 'content_rendered topic)) "\n\n")

        (insert (propertize (make-string (window-width) ?─) 'face 'font-lock-comment-face) "\n\n")
        (insert (propertize (format "Comments (%d/%d)" page total-pages) 'face 'bold) "\n\n")
        (dolist (reply replies)
          (let* ((r-m (alist-get 'member reply)) (r-user (alist-get 'username r-m)))
            (insert (propertize r-user 'face 'link 'v2ex-url (alist-get 'url r-m))
                    (if (string= r-user op-username) (propertize " [OP]" 'face 'font-lock-warning-face) "") ": \n")
            (insert (v2ex--render-html (alist-get 'content_rendered reply)) "\n")
            (insert (propertize (make-string 20 ?┄) 'face 'font-lock-comment-face) "\n\n")))
        (goto-char (point-min)))
      (display-buffer buffer))))

;;; --- Commands ---

;;;###autoload
(defun v2ex ()
  "Browse latest topics."
  (interactive)
  (v2ex--fetch-api "/topics/latest.json" (lambda (data) 
                                           (with-current-buffer (get-buffer-create "*V2EX*")
                                             (setq v2ex--current-node nil v2ex--current-node-title nil v2ex--current-page 1))
                                           (v2ex--render-list data))))

;;;###autoload
(defun v2ex-node (node-name)
  "Browse specific node."
  (interactive "sNode Name: ")
  (when (and node-name (not (string-empty-p node-name)))
    (v2ex--fetch-api (format "/v2/nodes/%s" node-name)
                     (lambda (node-info)
                       (let ((title (alist-get 'title (alist-get 'result node-info))))
                         (v2ex--fetch-api (format "/v2/nodes/%s/topics?p=1" node-name)
                                          (lambda (data)
                                            (with-current-buffer (get-buffer-create "*V2EX*")
                                              (setq v2ex--current-node node-name v2ex--current-node-title title v2ex--current-page 1))
                                            (v2ex--render-list data nil title)) t))) t)))

(defun v2ex-load-more ()
  "Load more topics."
  (interactive nil v2ex-mode)
  (when v2ex--current-node
    (let ((next-p (1+ v2ex--current-page)))
      (v2ex--fetch-api (format "/v2/nodes/%s/topics?p=%d" v2ex--current-node next-p)
                       (lambda (data) (setq v2ex--current-page next-p) (v2ex--render-list data t)) t))))

(defun v2ex--open-at-point ()
  "Handle Ret."
  (interactive nil v2ex-mode v2ex-view-mode)
  (let ((id (tabulated-list-get-id))
        (url (get-text-property (point) 'v2ex-url))
        (node-name (get-text-property (point) 'v2ex-node-name)))
    (cond (node-name (v2ex-node node-name))
          (url (browse-url url))
          ((and id (string-equal id "more")) (v2ex-load-more))
          (id (v2ex--fetch-topic-and-comments id))
          (t (message "No link found at point.")))))

(defun v2ex--fetch-topic-and-comments (id &optional p)
  "Fetch topic details."
  (when id
    (let ((page (or p 1)))
      (v2ex--fetch-api (format "/v2/topics/%s" id)
                       (lambda (t-j) (v2ex--fetch-api (format "/v2/topics/%s/replies?p=%d" id page)
                                                     (lambda (r-j) (v2ex--render-topic-page t-j r-j page)) t)) t))))

(defun v2ex--next-page () (interactive nil v2ex-view-mode) (v2ex--fetch-topic-and-comments v2ex--current-topic-id (1+ v2ex--current-page)))
(defun v2ex--prev-page () (interactive nil v2ex-view-mode) (when (> v2ex--current-page 1) (v2ex--fetch-topic-and-comments v2ex--current-topic-id (1- v2ex--current-page))))
(defun v2ex--refresh-current-topic () (interactive nil v2ex-view-mode) (v2ex--fetch-topic-and-comments v2ex--current-topic-id v2ex--current-page))

(provide 'v2ex)
