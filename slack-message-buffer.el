;;; slack-message-buffer.el ---                      -*- lexical-binding: t; -*-

;; Copyright (C) 2017

;; Author:  <yuya373@yuya373>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
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

;;

;;; Code:

(require 'eieio)
(require 'slack-room-buffer)

(defclass slack-message-buffer (slack-room-buffer)
  ((oldest :initform nil :type (or null string))
   (last-read :initform nil :type (or null string))))


(defmethod slack-buffer-update-mark ((this slack-message-buffer) message)
  (with-slots (room team) this
    (slack-room-update-mark room team message)))


(defmethod slack-buffer-send-message ((this slack-message-buffer) message)
  (with-slots (room team) this
    (slack-message-send-internal message (oref room id) team)))


(defmethod slack-buffer-buffer ((this slack-message-buffer))
  (let ((has-buffer (get-buffer (slack-buffer-name this)))
        (buffer (call-next-method)))
    (with-current-buffer buffer
      (slack-buffer-insert-latest-messages this)
      (unless has-buffer
        (goto-char (marker-position lui-input-marker))))
    buffer))

(defmethod slack-buffer-display-unread-threads ((this slack-message-buffer))
  (with-slots (room team) this
    (let* ((threads (mapcar #'(lambda (m) (oref m thread))
                            (cl-remove-if
                             #'(lambda (m)
                                 (or (not (slack-message-thread-parentp m))
                                     (not (< 0 (oref (oref m thread) unread-count)))))
                             (oref room messages))))
           (alist (mapcar #'(lambda (thread)
                              (cons (slack-thread-title thread team) thread))
                          (cl-sort threads
                                   #'string>
                                   :key #'(lambda (thread) (oref thread thread-ts)))))
           (selected (slack-select-from-list (alist "Select Thread: "))))
      (slack-thread-show-messages selected room team))))

(defmethod slack-buffer-start-thread ((this slack-message-buffer) ts)
  (with-slots (room team) this
    (let* ((message (slack-room-find-message room ts))
           (buf (slack-create-thread-message-buffer room team ts)))
      (if (object-of-class-p message 'slack-reply-broadcast-message)
          (error "Can't start thread from broadcasted message"))
      (slack-buffer-display buf))))

(defmethod slack-buffer-init-buffer ((this slack-message-buffer))
  (if-let* ((messages (slack-room-sorted-messages (oref this room)))
            (oldest-message (car messages)))
      (oset this oldest (oref oldest-message ts)))

  (let ((buf (call-next-method)))
    (with-current-buffer buf
      (slack-mode)
      (setq slack-current-buffer this)
      (add-hook 'kill-buffer-hook 'slack-message-buffer-on-killed nil t)
      (add-hook 'lui-pre-output-hook 'slack-buffer-buttonize-link nil t)
      (goto-char (point-min))
      (let ((lui-time-stamp-position nil))
        (lui-insert (format "%s\n" (slack-room-previous-link (oref this room))) t)))
    (oset (oref this room) buffer this)
    buf))

(defun slack-message-buffer-on-killed ()
  (if-let* ((buf (and (boundp 'slack-current-buffer)
                      slack-current-buffer)))
      (with-slots (room) buf
        (and room (oset room buffer nil)))))

(cl-defmethod slack-buffer-update ((this slack-message-buffer) message &key replace)
  (with-slots (room team buffer) this
    (slack-buffer-update-last-read this message)
    (if (slack-buffer-in-current-frame buffer)
        (slack-room-update-mark room team message)
      (slack-room-inc-unread-count room))
    (if replace (slack-buffer-replace this message)
      (with-current-buffer buffer (slack-buffer-insert message team)))))

(defmethod slack-buffer-display-message-compose-buffer ((this slack-message-buffer))
  (with-slots (room team) this
    (let ((buf (slack-message-compose-buffer :room room
                                             :team team)))
      (slack-buffer-display buf))))

(defmethod slack-buffer-message-delete ((this slack-message-buffer) ts)
  (with-slots (buffer) this
    (lui-delete #'(lambda () (equal (get-text-property (point) 'ts)
                                    ts)))))

(defmethod slack-buffer-update-last-read ((this slack-message-buffer) message)
  (with-slots (last-read) this
    (if (or (null last-read)
            (string< last-read (oref message ts)))
        (setq last-read (oref message ts)))))

(defmethod slack-buffer-insert-latest-messages ((this slack-message-buffer))
  (with-slots (room team last-read) this
    (let* ((messages (slack-room-sorted-messages room))
           (latest-message (car (last messages))))
      (cl-loop for m in messages
               do (if (or (null last-read)
                          (string< last-read (oref m ts)))
                      (slack-buffer-insert m team t)))
      (when latest-message
        (slack-buffer-update-last-read this latest-message)
        (slack-buffer-update-mark this latest-message)))))

(defmethod slack-buffer-display-thread ((this slack-message-buffer) ts)
  (with-slots (room team) this
    (let ((thread (slack-room-find-thread room ts)))
      (if thread (slack-thread-show-messages thread room team)
        (slack-thread-start)))))

(defmethod slack-buffer-display-edit-message-buffer ((this slack-message-buffer) ts)
  (with-slots (room team) this
    (let ((buf (slack-create-edit-message-buffer room team ts)))
      (slack-buffer-display buf))))

(defun slack-create-message-buffer (room team)
  (slack-message-buffer :room room :team team))

(defmethod slack-buffer-share-message ((this slack-message-buffer) ts)
  (with-slots (room team) this
    (let ((buf (slack-create-message-share-buffer room team ts)))
      (slack-buffer-display buf))))

(defmethod slack-buffer-add-reaction-to-message
  ((this slack-message-buffer) reaction ts)
  (with-slots (room team) this
    (slack-message-reaction-add reaction ts room team)))

(defmethod slack-buffer-remove-reaction-from-message
  ((this slack-message-buffer) ts)
  (with-slots (room team) this
    (let* ((message (slack-room-find-message room ts))
           ;; TODO
           (reactions (slack-message-reactions message))
           (reaction (slack-message-reaction-select reactions)))
      (if-let* ((file-comment-id (slack-get-file-comment-id)))
          (slack-file-comment-add-reaction file-comment-id reaction team)
        (slack-message-reaction-remove reaction ts room team)))))

(defmethod slack-buffer-pins-remove ((this slack-message-buffer) ts)
  (with-slots (room team) this
    (slack-message-pins-request slack-message-pins-remove-url
                                room team ts)))

(defmethod slack-buffer-pins-add ((this slack-message-buffer) ts)
  (with-slots (room team) this
    (slack-message-pins-request slack-message-pins-add-url
                                room team ts)))

(defmethod slack-buffer-copy-link ((this slack-message-buffer) ts)
  (with-slots (room team) this
    (if-let* ((message (or (slack-room-find-message room ts)
                           (slack-room-find-thread-message room ts)))
              (template "https://%s.slack.com/archives/%s/p%s%s"))
        (kill-new
         (format template
                 (oref team domain)
                 (oref room id)
                 (replace-regexp-in-string "\\." "" ts)
                 (if (slack-message-thread-messagep message)
                     (format "?thread_ts=%s&cid=%s"
                             (oref message thread-ts)
                             (oref room id))
                   ""))))))

(defmethod slack-buffer-remove-star ((this slack-message-buffer) ts)
  (with-slots (room team) this
    (if-let* ((message (slack-room-find-message room ts)))
        (slack-message-star-api-request slack-message-stars-remove-url
                                        (list (cons "channel" (oref room id))
                                              (slack-message-star-api-params message))
                                        team))))

(defmethod slack-buffer-add-star ((this slack-message-buffer) ts)
  (with-slots (room team) this
    (if-let* ((message (slack-room-find-message room ts)))
        (slack-message-star-api-request slack-message-stars-add-url
                                        (list (cons "channel" (oref room id))
                                              (slack-message-star-api-params message))
                                        team))))

(defmethod slack-buffer-update-oldest ((this slack-message-buffer) message)
  (when (and message (string< (oref message ts) (oref this oldest)))
    (oset this oldest (oref message ts))))

(defmethod slack-buffer-load-history ((this slack-message-buffer))
  (with-slots (room team oldest buffer) this
    (let ((current-ts (let ((change (next-single-property-change (point) 'ts)))
                        (when change
                          (get-text-property change 'ts))))
          (cur-point (point)))
      (cl-labels
          ((update-buffer
            (messages)
            (with-current-buffer buffer
              (slack-buffer-widen
               (let ((inhibit-read-only t))
                 (goto-char (point-min))

                 (if-let* ((loading-message-end (slack-buffer-ts-eq (point-min)
                                                                    (point-max)
                                                                    oldest)))
                     (delete-region (point-min) loading-message-end)
                   (message "loading-message-end not found, oldest: %s" oldest))

                 (set-marker lui-output-marker (point-min))

                 (let ((lui-time-stamp-position nil))
                   (if (and messages (< 0 (length messages)))
                       (lui-insert (format "%s\n"(slack-room-previous-link room)))
                     (lui-insert "(no more messages)\n")))

                 (cl-loop for m in messages
                          do (slack-buffer-insert m team t))
                 (lui-recover-output-marker)))
              (if current-ts
                  (slack-buffer-goto current-ts)
                (goto-char cur-point))))
           (after-success
            ()
            (let ((messages (cl-remove-if #'(lambda (e)
                                              (or (string< oldest e)
                                                  (string= oldest e)))
                                          (slack-room-sorted-messages room)
                                          :key #'(lambda (e) (oref e ts)))))
              (update-buffer messages)
              (slack-buffer-update-oldest this (car messages)))))
        (slack-room-history-request room team
                                    :oldest oldest
                                    :after-success #'after-success)))))

(defmethod slack-buffer-display-pins-list ((this slack-message-buffer))
  (with-slots (room team) this
    (cl-labels
        ((on-pins-list (&key data &allow-other-keys)
                       (slack-request-handle-error
                        (data "slack-room-pins-list")
                        (let* ((buf (slack-create-pinned-items-buffer
                                     room team (plist-get data :items))))
                          (slack-buffer-display buf)))))
      (slack-request
       (slack-request-create
        slack-room-pins-list-url
        team
        :params (list (cons "channel" (oref room id)))
        :success #'on-pins-list)))))

(defmethod slack-buffer-display-user-profile ((this slack-message-buffer))
  (with-slots (room team) this
    (let* ((members (cl-remove-if
                     #'(lambda (e)
                         (or (slack-user-self-p e team)
                             (slack-user-hidden-p
                              (slack-user--find e team))))
                     (slack-room-get-members room)))
           (user-alist (mapcar #'(lambda (u) (cons (slack-user-name u team) u))
                               members))
           (user-id (if (eq 1 (length members))
                        (car members)
                      (slack-select-from-list (user-alist "Select User: ")))))
      (let ((buf (slack-create-user-profile-buffer team user-id)))
        (slack-buffer-display buf)))))

(provide 'slack-message-buffer)
;;; slack-message-buffer.el ends here