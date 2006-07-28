;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp -*-

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;   Copyright (C) 2006 by Stelian Ionescu                                 ;
;                                                                         ;
;   This program is free software; you can redistribute it and/or modify  ;
;   it under the terms of the GNU General Public License as published by  ;
;   the Free Software Foundation; either version 2 of the License, or     ;
;   (at your option) any later version.                                   ;
;                                                                         ;
;   This program is distributed in the hope that it will be useful,       ;
;   but WITHOUT ANY WARRANTY; without even the implied warranty of        ;
;   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         ;
;   GNU General Public License for more details.                          ;
;                                                                         ;
;   You should have received a copy of the GNU General Public License     ;
;   along with this program; if not, write to the                         ;
;   Free Software Foundation, Inc.,                                       ;
;   51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; (declaim (optimize (speed 2) (safety 2) (space 1) (debug 2)))
(declaim (optimize (speed 0) (safety 2) (space 0) (debug 2)))

(in-package #:net.sockets)

(defparameter *socket-type-map*
  '(((:ipv4 :stream   :active  :default) . socket-stream-internet-active)
    ((:ipv6 :stream   :active  :default) . socket-stream-internet-active)
    ((:ipv4 :stream   :passive :default) . socket-stream-internet-passive)
    ((:ipv6 :stream   :passive :default) . socket-stream-internet-passive)
    ((:unix :stream   :active  :default) . socket-stream-local-active)
    ((:unix :stream   :passive :default) . socket-stream-local-passive)
    ((:unix :datagram :active  :default) . socket-datagram-local-active)
    ((:ipv4 :datagram :active  :default) . socket-datagram-internet-active)
    ((:ipv6 :datagram :active  :default) . socket-datagram-internet-active)))

(defun select-socket-type (family type connect protocol)
  (or (cdr (assoc (list family type connect protocol) *socket-type-map*
                  :test #'equal))
      (error "No socket class found !!")))

;;;;;;;;;;;;;;;;;;;;;;;;;
;;  SHARED-INITIALIZE  ;;
;;;;;;;;;;;;;;;;;;;;;;;;;

(defun translate-make-socket-keywords-to-constants (family type protocol)
  (let ((sf (ecase family
              (:ipv4  et:af-inet)
              (:ipv6  et:af-inet6)
              (:local et:af-local)))
        (st (ecase type
              (:stream   et:sock-stream)
              (:datagram et:sock-dgram)))
        (sp (cond
              ((integerp protocol) protocol)
              ((eql protocol :default) 0)
              ((keywordp protocol)
               (protocol-number
                (get-protocol-by-name (string-downcase
                                       (string protocol))))))))
    (values sf st sp)))

(defun set-finalizer-on-socket (socket fd)
  (sb-ext:finalize socket #'(lambda () (et:close fd))))

(defmethod shared-initialize :after ((socket socket) slot-names
                                     &key file-descriptor family
                                     type (protocol :default))
  (when (socket-open-p socket)
    (socket-close socket))
  (with-slots (fd (fam family) (proto protocol)) socket
    (multiple-value-bind (sf st sp)
        (translate-make-socket-keywords-to-constants family type protocol)
      (if file-descriptor
          (setf fd file-descriptor)
          (setf fd (with-socket-error-filter
                     (et:socket sf st sp))))
      (setf fam family)
      (setf proto protocol)
      (set-finalizer-on-socket socket fd))))

(defmethod shared-initialize :after ((socket stream-socket) slot-names &key)
  (setf (slot-value socket 'lisp-stream)
        (sb-sys:make-fd-stream (socket-fd socket)
                               :name (format nil "Socket stream, fd: ~a" (socket-fd socket))
                               :input t :output t :buffering :none :dual-channel-p t
                               :element-type :default :auto-close nil)))

(defmethod socket-type ((socket stream-socket))
  :stream)

(defmethod socket-type ((socket datagram-socket))
  :datagram)

;;;;;;;;;;;;;
;;  CLOSE  ;;
;;;;;;;;;;;;;

(defmethod socket-close progn ((socket socket))
  (when (slot-boundp socket 'fd)
    (with-socket-error-filter
      (et:close (socket-fd socket))))
  (sb-ext:cancel-finalization socket)
  (mapc #'(lambda (slot)
            (slot-makunbound socket slot))
        '(fd address family protocol))
  socket)

(defmethod socket-close progn ((socket stream-socket))
  (slot-makunbound socket 'lisp-stream))

(defmethod socket-close progn ((socket internet-socket))
  (slot-makunbound socket 'port))

(defmethod socket-open-p ((socket socket))
  (unless (slot-boundp socket 'fd)
    (return-from socket-open-p nil))
  (with-socket-error-filter
    (handler-case
        (with-alien ((ss et:sockaddr-storage)
                     (size et:socklen-t
                           #.et::size-of-sockaddr-storage))
          (let ((ssptr (addr ss)))
            (et:getsockname (socket-fd socket)
                            ssptr (addr size))
            t))
      (unix-error (err)
        (case (error-identifier err)
          ((:ebadf
            :enotsock
            :econnreset)
           nil)
          ;; some other error
          (otherwise (error err)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;  get and set O_NONBLOCK  ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defmethod socket-non-blocking-mode ((socket socket))
  (with-slots (fd) socket
    (let ((file-flags (with-socket-error-filter
                        (et:fcntl fd et:f-getfl))))
      (not (zerop (logand file-flags et:o-nonblock))))))

(defmethod (setf socket-non-blocking-mode) (value (socket socket))
  (check-type value boolean "a boolean value")
  (with-slots (fd) socket
    (let ((file-flags (et:fcntl fd et:f-getfl)))
      (with-socket-error-filter
        (et:fcntl fd et:f-setfl
                  (logior file-flags
                          (if value et:o-nonblock 0))))))
  value)

;;;;;;;;;;;;;;;;;;;
;;  GETSOCKNAME  ;;
;;;;;;;;;;;;;;;;;;;

(defmethod local-name ((socket internet-socket))
  (with-alien ((ss et:sockaddr-storage)
               (size et:socklen-t
                     #.et::size-of-sockaddr-storage))
    (let ((ssptr (addr ss)))
      (with-socket-error-filter
        (et:getsockname (socket-fd socket)
                        ssptr (addr size)))
      (return-from local-name
        (values (sockaddr-storage->netaddr ssptr)
                (ntohs (slot (cast ssptr (* et:sockaddr-in))
                             'et:port)))))))
(defmethod local-name ((socket local-socket))
  (with-alien ((sun et:sockaddr-un)
               (size et:socklen-t
                     #.et::size-of-sockaddr-un))
    (let ((sunptr (addr sun)))
      (with-socket-error-filter
        (et:getsockname (socket-fd socket)
                        sunptr (addr size)))
      (return-from local-name
        (values (sockaddr-un->netaddr sunptr))))))

;;;;;;;;;;;;;;;;;;;
;;  GETPEERNAME  ;;
;;;;;;;;;;;;;;;;;;;

(defmethod remote-name ((socket internet-socket))
  (with-alien ((ss et:sockaddr-storage)
               (size et:socklen-t
                     #.et::size-of-sockaddr-storage))
    (let ((ssptr (addr ss)))
      (with-socket-error-filter
        (et:getpeername (socket-fd socket)
                        ssptr (addr size)))
      (return-from remote-name
        (values (sockaddr-storage->netaddr ssptr)
                (ntohs (slot (cast ssptr (* et:sockaddr-in))
                             'et:port)))))))

(defmethod remote-name ((socket local-socket))
  (with-alien ((sun et:sockaddr-un)
               (size et:socklen-t
                     #.et::size-of-sockaddr-un))
    (let ((sunptr (addr sun)))
      (with-socket-error-filter
        (et:getpeername (socket-fd socket)
                        sunptr (addr size)))
      (return-from remote-name
        (values (sockaddr-un->netaddr sunptr))))))

;;;;;;;;;;;;
;;  BIND  ;;
;;;;;;;;;;;;

(defmethod bind-address :before ((socket internet-socket)
                                 address &key (reuse-address t))
  (when reuse-address
    (set-socket-option socket :reuse-address :value t)))

(defmethod bind-address ((socket internet-socket)
                         (address ipv4addr)
                         &key (port 0) interface)
  (with-alien ((sin et:sockaddr-in))
    (make-sockaddr-in (addr sin) (name address) port)
    (with-socket-error-filter
      (et:bind (socket-fd socket)
               (addr sin)
               et::size-of-sockaddr-in)))
  (values))

(defmethod bind-address ((socket internet-socket)
                         (address ipv6addr)
                         &key (port 0) interface)
  (with-alien ((sin6 et:sockaddr-in6))
    (make-sockaddr-in6 (addr sin6) (name address) port)
    (with-socket-error-filter
      (et:bind (socket-fd socket)
               (addr sin6)
               et::size-of-sockaddr-in6)))
  (values))

(defmethod bind-address :before ((socket local-socket)
                                 (address localaddr) &key)
  (when (typep socket 'active-socket)
    (error "You can't bind an active Unix socket.")))

(defmethod bind-address ((socket local-socket)
                         (address localaddr) &key)
  (with-alien ((sun et:sockaddr-un))
    (make-sockaddr-un (addr sun) (name address))
    (with-socket-error-filter
      (et:bind (socket-fd socket)
               (addr sun)
               et::size-of-sockaddr-un)))
  (values))

(defmethod bind-address :after ((socket socket)
                                (address netaddr) &key)
  (setf (slot-value socket 'address) (copy-netaddr address)))

(defmethod bind-address :after ((socket internet-socket)
                                (address netaddr) &key port)
  (setf (slot-value socket 'port) port))


;;;;;;;;;;;;;;
;;  LISTEN  ;;
;;;;;;;;;;;;;;

(defmethod socket-listen ((socket passive-socket)
                          &key (backlog (min *default-backlog-size*
                                             +max-backlog-size+)))
  (check-type backlog unsigned-byte "a non-negative integer")
  (with-socket-error-filter
    (et:listen (socket-fd socket) backlog))
  (values))

(defmethod socket-listen ((socket active-socket)
                          &key backlog)
  (declare (ignore backlog))
  (error "You can't listen on active sockets."))

;;;;;;;;;;;;;;
;;  ACCEPT  ;;
;;;;;;;;;;;;;;

(defmethod accept-connection ((socket active-socket)
                              &key wait)
  (declare (ignore wait))
  (error "You can't accept connections on active sockets."))

(defmethod accept-connection ((socket passive-socket)
                              &key (wait t))
  (with-alien ((ss et:sockaddr-storage)
               (size et:socklen-t
                     #.et::size-of-sockaddr-storage))
    (let (non-blocking-state
          client-fd)
      (with-socket-error-filter
        (handler-case
            (if wait
                ;; do a "normal" accept
                ;; Note: the socket may already be in non-blocking mode
                (setf client-fd (et:accept (socket-fd socket)
                                           (addr ss) (addr size)))
                ;; set the socket to non-blocking mode before calling accept()
                ;; if there's no new connection return NIL
                (unwind-protect
                     (progn
                       ;; saving the current non-blocking state
                       (setf non-blocking-state (socket-non-blocking-mode socket))
                       (setf client-fd (et:accept (socket-fd socket)
                                                  (addr ss) (addr size))))
                  ;; restoring the socket's non-blocking state
                  (setf (socket-non-blocking-mode socket) non-blocking-state)))
          ;; the socket is marked non-blocking and there's no new connection
          (et:unix-error-wouldblock (err)
            (declare (ignore err))
            (return-from accept-connection nil))))

      (let ((client-socket
             ;; create the client socket object
             (make-instance (select-socket-type (socket-family   socket)
                                                (socket-type     socket)
                                                :active
                                                (socket-protocol socket))
                            :file-descriptor client-fd)))
        ;; setting the socket's remote address and port
        (multiple-value-bind (remote-address remote-port)
            (remote-name client-socket)
          (setf (slot-value client-socket 'address) remote-address)
          ;; when it's an internet socket
          (when remote-port
            (setf (slot-value client-socket 'port) remote-port)))
        (return-from accept-connection client-socket)))))


;;;;;;;;;;;;;;;
;;  CONNECT  ;;
;;;;;;;;;;;;;;;

#+freebsd
(defmethod connect :before ((socket active-socket)
                            netaddr &key)
  (when *no-sigpipe*
    (set-socket-option socket :no-sigpipe :value t)))

(defmethod connect ((socket internet-socket)
                    (address ipv4addr) &key (port 0))
  (with-alien ((sin et:sockaddr-in))
    (make-sockaddr-in (addr sin) (name address) port)
    (with-socket-error-filter
      (et:connect (socket-fd socket)
                  (addr sin)
                  et::size-of-sockaddr-in))
    (setf (slot-value socket 'port) port))
  (values))

(defmethod connect ((socket internet-socket)
                    (address ipv6addr) &key (port 0))
  (with-alien ((sin6 et:sockaddr-in6))
    (make-sockaddr-in6 (addr sin6) (name address) port)
    (with-socket-error-filter
      (et:connect (socket-fd socket)
                  (addr sin6)
                  et::size-of-sockaddr-in6))
    (setf (slot-value socket 'port) port))
  (values))

(defmethod connect ((socket local-socket)
                    (address localaddr) &key)
  (with-alien ((sun et:sockaddr-un))
    (make-sockaddr-un (addr sun) (name address))
    (with-socket-error-filter
      (et:connect (socket-fd socket)
                  (addr sun)
                  et::size-of-sockaddr-un)))
  (values))

(defmethod connect :after ((socket active-socket)
                           (address netaddr) &key)
  (setf (slot-value socket 'address) (copy-netaddr address)))

(defmethod connect ((socket passive-socket)
                    address &key)
  (error "You cannot connect passive sockets."))

;;;;;;;;;;;;;;;;
;;  SHUTDOWN  ;;
;;;;;;;;;;;;;;;;

(defmethod shutdown ((socket active-socket) direction)
  (check-type direction (member :read :write :read-write)
              "valid shutdown specifier")
  (with-socket-error-filter
    (et:shutdown (socket-fd socket)
                 (ecase direction
                   (:read et:shut-rd)
                   (:write et:shut-wr)
                   (:read-write et:shut-rdwr))))
  socket)

(defmethod shutdown ((socket passive-socket) direction)
  (error "You cannot shut down passive sockets."))

;;;;;;;;;;;;
;;  SEND  ;;
;;;;;;;;;;;;

(defun normalize-send-buffer (buff length)
  (check-type length (or unsigned-byte null)
              "a non-negative value or NIL")
  (let ((end (if length
                 (min length (length buff))
                 (length buff))))
    (etypecase buff
      ((simple-array ub8 (*)) (values buff end))
      (simple-base-string (values buff end))
      (string (values (sb-ext:string-to-octets buff :end end)
                      end)))))

(defmethod socket-send ((buffer simple-array)
                        (socket active-socket) &key length
                        remote-address remote-port end-of-record
                        dont-route dont-wait (no-signal *no-sigpipe*)
                        out-of-band #+linux more #+linux confirm)
  (let ((flags (logior (if end-of-record et:msg-eor 0)
                       (if dont-route et:msg-dontroute 0)
                       (if dont-wait  et:msg-dontwait 0)
                       (if no-signal  et:msg-nosignal 0)
                       (if out-of-band et:msg-oob 0)
                       #+linux (if more et:msg-more 0)
                       #+linux (if confirm et:msg-confirm 0))))
    (multiple-value-bind (buff bufflen)
        (normalize-send-buffer buffer length)
      (with-alien ((ss et:sockaddr-storage))
        (when remote-address
          (netaddr->sockaddr-storage ss remote-address remote-port))
        (with-vector-saps ((buff-sap buff))
          (with-socket-error-filter
            (return-from socket-send
              (et:sendto (socket-fd socket)
                         buff-sap bufflen
                         flags
                         (if remote-address (addr ss) nil)
                         (if remote-address et::size-of-sockaddr-storage 0)))))))))

(defmethod socket-send (buffer (socket passive-socket) &key)
  (error "You cannot send data on a passive socket."))

;;;;;;;;;;;;
;;  RECV  ;;
;;;;;;;;;;;;

(defun normalize-receive-buffer (buff length)
  (check-type length (or unsigned-byte null)
              "a non-negative value or NIL")
  (let ((end (if length
                 (min length (length buff))
                 (length buff))))
    (etypecase buff
      ((simple-array ub8 (*)) (values buff end))
      (simple-base-string (values buff end)))))

(defmethod socket-receive ((buffer simple-array)
                           (socket active-socket) &key length
                           remote-address out-of-band peek wait-all
                           dont-wait trunc (no-signal *no-sigpipe*))

  (check-type buffer (simple-array ub8 (*)))
  (check-type length (or unsigned-byte null)
              "a non-negative value or NIL")

  (let ((flags (logior (if out-of-band et:msg-oob 0)
                       (if peek        et:msg-peek 0)
                       (if wait-all    et:msg-waitall 0)
                       (if dont-wait   et:msg-dontwait 0)
                       (if trunc       et:msg-trunc 0)
                       (if no-signal   et:msg-nosignal 0))))
    (multiple-value-bind (buff bufflen)
        (normalize-receive-buffer buffer length)
      (with-alien ((ss et:sockaddr-storage)
                   (size et:socklen-t #.et::size-of-sockaddr-storage))
        (when remote-address
          (netaddr->sockaddr-storage ss remote-address))
        (with-vector-saps ((buff-sap buff))
          (with-socket-error-filter
            (return-from socket-receive
              (et:recvfrom (socket-fd socket)
                           buff-sap bufflen
                           flags
                           (if remote-address (addr ss) nil)
                           (if remote-address (addr size) nil)))))))))

(defmethod socket-receive (buffer (socket passive-socket) &key)
  (error "You cannot receive data from a passive socket."))


;;
;; Only for datagram sockets
;;

(defmethod unconnect :before ((socket active-socket))
  (unless (typep socket 'datagram-socket)
    (error "You can only unconnect active datagram sockets.")))

(defmethod unconnect ((socket datagram-socket))
  (with-socket-error-filter
    (with-alien ((sin et:sockaddr-in))
      (et:memset (addr sin) 0 et::size-of-sockaddr-in)
      (setf (slot sin 'et:address) et:af-unspec)
      (et:connect (socket-fd socket)
                  (addr sin)
                  et::size-of-sockaddr-in)
      (slot-makunbound socket 'address)
      (when (typep socket 'internet-socket)
        (slot-makunbound socket 'port)))))
