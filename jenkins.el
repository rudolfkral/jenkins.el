;; jenkins.el --- small iteraction library for jenkins

;;; Commentary:

;; To proper installation, please define variables as it shown below:
;;
;; (setq jenkins-api-token "<api token can be found on user's configure page>")
;; (setq jenkins-hostname "<jenkins url>")
;; (setq jenkins-username "<your user name>")
;; (setq jenkins-viewname "<viewname>")

;;; Code:

(require 'dash)

(defconst jenkins-buffer-name
  "*jenkins-status*"
  "Name of jenkins buffer.")

(defun jenkins--render-name (item)
  (let ((jobname (plist-get item :name))
        (progress (plist-get item :progress)))
    (if progress
        (format "%s %s"
                (propertize (format "%s%%" progress) 'font-lock-face 'warning)
                jobname)
      (format "%s" jobname)))
  )

(defconst jenkins-list-format
  [("#" 3 f :pad-right 2 :right-align t :col-source jenkins--render-indicator)
   ("Name" 35 t :col-source jenkins--render-name)
   ("Last success" 20 f :col-source :last-success)
   ("Last failed" 20 f :col-source :last-failed)]
  "Columns format.")

(defvar *jenkins-local-mode* nil)

(defvar jenkins-api-token nil)
(defvar jenkins-hostname nil)
(defvar jenkins-username nil)
(defvar jenkins-viewname nil)

(defvar *jenkins-jobs-list* nil)

(defun jenkins-jobs-view-url (hostname viewname)
  "Jenkins url for get list of jobs in queue and their summaries"
  (format (concat
           "%sview/%s/api/json?depth=2&tree=name,jobs[name,"
           "lastSuccessfulBuild[result,timestamp,duration,id],"
           "lastFailedBuild[result,timestamp,duration,id],"
           "lastBuild[result,executor[progress]],"
           "lastCompletedBuild[result]]"
           )
          hostname viewname))

(defun jenkins-job-url (hostname jobname)
  (format (concat
           "%sjob/%s/"
           "api/json?depth=1&tree=builds"
           "[id,timestamp,result,url,building,"
           "culprits[fullName]]")
          hostname jobname))

(defun jenkins--setup-variables ()
  "Ask from user required variables if they not defined yet"
  (unless jenkins-hostname
    (setq jenkins-hostname (read-from-minibuffer "Jenkins hostname: ")))
  (unless jenkins-viewname
    (setq jenkins-viewname (read-from-minibuffer "Jenkins viewname: ")))
  (unless jenkins-username
    (setq jenkins-username (read-from-minibuffer "Jenkins username: ")))
  (unless jenkins-api-token
    (setq jenkins-api-token (read-from-minibuffer "Jenkins API Token: "))))

;; models

(defun jenkins--make-job (name result progress last-success last-failed)
  "Define regular jenkins job here."
  (list :name name
        :result result
        :progress progress
        :last-success last-success
        :last-failed last-failed))

(defun jenkins--render-indicator (job)
  "Special indicator on main jenkins window."
  (let ((result (plist-get job :result))
        (facemap (list
                  '("SUCCESS" . 'success)
                  '("FAILURE" . 'error)
                  '("ABORTED" . 'warning))))
    (propertize "●" 'font-lock-face (cdr (assoc result facemap))))
  )

(defun jenkins--convert-jobs-to-tabulated-format ()
  "Use global jenkins-jobs-list prepare data from table"
  (--map
   (list
    (plist-get it :name)
    (apply 'vector (-map
     (lambda (column)
       (let* ((args (nthcdr 3 column))
              (col-source (plist-get args :col-source)))
         (if (functionp col-source)
             (funcall col-source it)
           (plist-get it col-source))))
     jenkins-list-format)))
   (mapcar 'cdr *jenkins-jobs-list*)
   ))

;;; actions

(defun jenkins:enter-job (&optional jobindex)
  "Open each job detalization page"
  (interactive)
  (let ((jobindex (or jobindex (tabulated-list-get-id))))
    (jenkins-job-view jobindex)))

(defun jenkins:restart-job (&optional jobindex)
  "Build jenkins job"
  (interactive)
  (let (index (tabulated-list-get-id))
    index))

(defun jenkins--time-since-to-text (timestamp)
  "Returns beatiful string presenting time since event"

  (defun jenkins--parse-time-from (time-since timeitems)
    (let* ((timeitem (car timeitems))
           (extracted-time (mod time-since (cdr timeitem)))
           (rest-time (/ (- time-since extracted-time) (cdr timeitem)))
           )
      (if (cdr timeitems)
          (apply 'list
                 (list extracted-time (car timeitem))
                 (jenkins--parse-time-from rest-time (cdr timeitems)))
        (list (list time-since (car timeitem)))
        )))

  (let* ((timeitems
          '(("s" . 60) ("m" . 60)
            ("h" . 24) ("d" . 1)))
         (seconds-since (- (float-time) timestamp))
         (time-pairs (jenkins--parse-time-from seconds-since timeitems))
         )
    (mapconcat
     (lambda (values) (apply 'format "%d%s" values))
     (-take 3 (reverse (--filter (not (= (car it) 0)) time-pairs)))
     ":")))

(defun jenkins--refresh-jobs-list ()
  "Force loading reloading jobs from jenkins and return them formatter for table"
  (jenkins-get-jobs-list)
  (jenkins--convert-jobs-to-tabulated-format))

(defun jenkins--retrieve-page-as-json (url)
  "Shortcut for jenkins api to return valid json"
  (let* ((url-request-extra-headers
          `(("Content-Type" . "application/x-www-form-urlencoded")
            ("Authorization" .
             ,(concat
               "Basic "
               (base64-encode-string
                (concat jenkins-username ":" jenkins-api-token)))))))
    (with-current-buffer (url-retrieve-synchronously url)
      (goto-char (point-min))
      (re-search-forward "^$")
      (delete-region (point) (point-min))
      (json-read-from-string (buffer-string)))
    ))

(defun jenkins--extract-time-of-build (x buildname)
  "Helper defun to render timstamps"
  (let ((val (cdr (assoc 'timestamp (assoc buildname x)))))
    (if val (jenkins--time-since-to-text (/ val 1000)) "")))

(defun jenkins-get-jobs-list ()
  "Get list of jobs from jenkins server"
  (let* ((jobs-url (jenkins-jobs-view-url jenkins-hostname jenkins-viewname))
         (raw-data (jenkins--retrieve-page-as-json jobs-url))
         (jobs (cdr (assoc 'jobs raw-data))))
    (setq *jenkins-jobs-list*
          (--map
           (apply 'list (cdr (assoc 'name it))
                  (jenkins--make-job
                   (cdr (assoc 'name it))
                   (cdr (assoc 'result (assoc 'lastCompletedBuild it)))
                   (cdr (assoc 'progress (assoc 'executor (assoc 'lastBuild it))))
                   (jenkins--extract-time-of-build it 'lastSuccessfulBuild)
                   (jenkins--extract-time-of-build it 'lastFailedBuild)))
           jobs)
    ))
  )

(defun jenkins-get-job-details (jobname)
  "Make to certain job call"
  (let* ((job-url (jenkins-job-url jenkins-hostname jobname))
         (raw-data (jenkins--retrieve-page-as-json job-url)))
    raw-data))

;; helpers

(defun jenkins:visit-jenkins-web-page ()
  "Open jenkins web page using predefined variables."
  (interactive)
  (unless jenkins-hostname
    (setq jenkins-hostname (read-from-minibuffer "Jenkins hostname: ")))
  (browse-url jenkins-hostname))

(defvar jenkins-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "r") 'jenkins:restart-job)
    (define-key map (kbd "RET") 'jenkins:enter-job)
    map)
  "Jenkins status mode keymap.")

;; emacs major mode funcs and variables

(define-derived-mode jenkins-mode tabulated-list-mode "Jenkins"
  "Special mode for jenkins status buffer"
  (setq truncate-lines t)
  (kill-all-local-variables)
  (setq mode-name "Jenkins")
  (setq major-mode 'jenkins-mode)
  (use-local-map jenkins-mode-map)
  (hl-line-mode 1)
  (setq tabulated-list-format jenkins-list-format)
  (setq tabulated-list-entries 'jenkins--refresh-jobs-list)
  (tabulated-list-init-header)
  (tabulated-list-print)
  )

(define-derived-mode jenkins-job-view-mode special-mode "Jenkins job"
  "Mode for viewing jenkins job details"
  (view-mode 1)
  (font-lock-mode 1)

  ;; buffer defaults
  (setq-local local-jobname jobname)
  (setq-local local-jobs-shown nil)
  )

(defun jenkins-job-render (jobname)
  (setq buffer-read-only nil)
  (erase-buffer)
  (let ((job (cdr (assoc jobname *jenkins-jobs-list*))))
    (insert
     (jenkins-job-details-screen
      jobname (plist-get job :result) "id 495" "id 455" "N")
     ))
  (setq buffer-read-only t)
  )

(defun jenkins-job-view (jobname)
  "Open job details"
  (interactive)
  (setq local-jobs-shown t)
  (let ((details-buffer-name (format "*%s details*" jobname)))
    (switch-to-buffer details-buffer-name)
    (jenkins-job-render jobname)
    (jenkins-job-view-mode)
    ))

(defun jenkins-job-details-toggle ()
  (interactive)
  (setq-local local-jobs-shown (not local-jobs-shown))
  (let ((prev (point)))
    (progn
      (jenkins-job-render local-jobname)
      (goto-char prev)
      )))

(defun jenkins-job-details-screen (&rest params)
  "Jenkins job detailization screen"
  (let* ((jobs-keymap
          (let ((keymap (make-sparse-keymap)))
            (progn
              (define-key keymap (kbd "1") 'jenkins-job-details-toggle)
              (define-key keymap (kbd "2") 'jenkins-job-details-toggle)
              keymap)))
         (formatted-string
           (concat
            "Job name: %s\nStatus: "
            (propertize "%s!" 'face 'warning 'keymap jobs-keymap)
            "\n\n"
            (format "toggling: %s\n" local-jobs-shown)
            "Latest builds:\n"
            "- success: %s\n"
            "- failed: %s\n"
            "or review other %s jobs\n\n"
            (propertize "Build now!" 'face 'error)
            ))
         )
    (apply 'format formatted-string params)
    ))


(defun jenkins ()
  "Initialize jenkins buffer."
  (interactive)
  (jenkins--setup-variables)
  (switch-to-buffer-other-window jenkins-buffer-name)
  (erase-buffer)
  (setq buffer-read-only t)
  (jenkins-mode)
)

(provide 'jenkins)
;;; jenkins ends here
