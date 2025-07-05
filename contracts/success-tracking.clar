;; Success Tracking Contract
;; Measures relationship outcome metrics

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u500))
(define-constant ERR_RELATIONSHIP_NOT_FOUND (err u501))
(define-constant ERR_INVALID_INPUT (err u502))
(define-constant ERR_ALREADY_EXISTS (err u503))
(define-constant ERR_INSUFFICIENT_BALANCE (err u504))

;; Data Variables
(define-data-var next-relationship-id uint u1)
(define-data-var success-reward-amount uint u1000000) ;; 1 STX
(define-data-var platform-fee-percentage uint u5) ;; 5%

;; Data Maps
(define-map relationships
  { relationship-id: uint }
  {
    participant1: uint,
    participant2: uint,
    started-at: uint,
    status: (string-ascii 20),
    success-score: uint,
    milestones-reached: uint,
    last-updated: uint,
    ended-at: (optional uint),
    end-reason: (optional (string-ascii 100))
  }
)

(define-map relationship-milestones
  { relationship-id: uint, milestone-type: (string-ascii 30) }
  {
    achieved-at: uint,
    reported-by: uint,
    verified: bool,
    reward-distributed: bool
  }
)

(define-map user-success-metrics
  { user-id: uint }
  {
    total-relationships: uint,
    successful-relationships: uint,
    average-relationship-duration: uint,
    success-rate: uint,
    total-rewards-earned: uint,
    reputation-bonus: uint,
    last-calculated: uint
  }
)

(define-map platform-metrics
  { metric-type: (string-ascii 30), period: uint }
  {
    value: uint,
    calculated-at: uint,
    sample-size: uint
  }
)

(define-map success-rewards
  { user-id: uint, relationship-id: uint }
  {
    base-reward: uint,
    bonus-reward: uint,
    total-reward: uint,
    distributed-at: uint,
    milestone-rewards: uint
  }
)

;; Public Functions

;; Start tracking a new relationship
(define-public (start-relationship (participant1 uint) (participant2 uint))
  (let
    (
      (relationship-id (var-get next-relationship-id))
    )
    (asserts! (not (is-eq participant1 participant2)) ERR_INVALID_INPUT)

    (map-set relationships
      { relationship-id: relationship-id }
      {
        participant1: participant1,
        participant2: participant2,
        started-at: block-height,
        status: "active",
        success-score: u0,
        milestones-reached: u0,
        last-updated: block-height,
        ended-at: none,
        end-reason: none
      }
    )

    (update-user-relationship-count participant1)
    (update-user-relationship-count participant2)
    (var-set next-relationship-id (+ relationship-id u1))

    (ok relationship-id)
  )
)

;; Report a relationship milestone
(define-public (report-milestone
  (relationship-id uint)
  (milestone-type (string-ascii 30))
  (reporter-id uint)
)
  (let
    (
      (relationship (unwrap! (map-get? relationships { relationship-id: relationship-id }) ERR_RELATIONSHIP_NOT_FOUND))
    )
    (asserts! (is-eq (get status relationship) "active") ERR_INVALID_INPUT)
    (asserts! (or (is-eq reporter-id (get participant1 relationship))
                  (is-eq reporter-id (get participant2 relationship))) ERR_NOT_AUTHORIZED)

    (map-set relationship-milestones
      { relationship-id: relationship-id, milestone-type: milestone-type }
      {
        achieved-at: block-height,
        reported-by: reporter-id,
        verified: false,
        reward-distributed: false
      }
    )

    (map-set relationships
      { relationship-id: relationship-id }
      (merge relationship {
        milestones-reached: (+ (get milestones-reached relationship) u1),
        success-score: (+ (get success-score relationship) (calculate-milestone-score milestone-type)),
        last-updated: block-height
      })
    )

    (ok true)
  )
)

;; Verify a milestone (admin or automated system)
(define-public (verify-milestone (relationship-id uint) (milestone-type (string-ascii 30)) (verified bool))
  (let
    (
      (milestone (unwrap! (map-get? relationship-milestones
                                  { relationship-id: relationship-id, milestone-type: milestone-type })
                         ERR_RELATIONSHIP_NOT_FOUND))
    )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)

    (map-set relationship-milestones
      { relationship-id: relationship-id, milestone-type: milestone-type }
      (merge milestone { verified: verified })
    )

    (if verified
      (distribute-milestone-reward relationship-id milestone-type)
      (ok false))
  )
)

;; End a relationship
(define-public (end-relationship
  (relationship-id uint)
  (end-reason (string-ascii 100))
  (reporter-id uint)
)
  (let
    (
      (relationship (unwrap! (map-get? relationships { relationship-id: relationship-id }) ERR_RELATIONSHIP_NOT_FOUND))
    )
    (asserts! (is-eq (get status relationship) "active") ERR_INVALID_INPUT)
    (asserts! (or (is-eq reporter-id (get participant1 relationship))
                  (is-eq reporter-id (get participant2 relationship))) ERR_NOT_AUTHORIZED)

    (map-set relationships
      { relationship-id: relationship-id }
      (merge relationship {
        status: "ended",
        ended-at: (some block-height),
        end-reason: (some end-reason),
        last-updated: block-height
      })
    )

    (calculate-final-success-score relationship-id)
    (update-user-success-metrics (get participant1 relationship) relationship-id)
    (update-user-success-metrics (get participant2 relationship) relationship-id)

    (ok true)
  )
)

;; Distribute success rewards
(define-public (distribute-success-reward (participant-id uint) (relationship-id uint))
  (let
    (
      (relationship (unwrap! (map-get? relationships { relationship-id: relationship-id }) ERR_RELATIONSHIP_NOT_FOUND))
      (user-metrics (unwrap! (map-get? user-success-metrics { user-id: participant-id }) ERR_RELATIONSHIP_NOT_FOUND))
      (base-reward (var-get success-reward-amount))
      (bonus-multiplier (calculate-bonus-multiplier (get success-rate user-metrics)))
      (bonus-reward (* base-reward bonus-multiplier))
      (total-reward (+ base-reward bonus-reward))
    )
    (asserts! (is-eq (get status relationship) "ended") ERR_INVALID_INPUT)
    (asserts! (>= (get success-score relationship) u70) ERR_INVALID_INPUT) ;; Minimum success threshold

    (map-set success-rewards
      { user-id: participant-id, relationship-id: relationship-id }
      {
        base-reward: base-reward,
        bonus-reward: bonus-reward,
        total-reward: total-reward,
        distributed-at: block-height,
        milestone-rewards: u0
      }
    )

    ;; In a real implementation, this would transfer actual tokens
    (map-set user-success-metrics
      { user-id: participant-id }
      (merge user-metrics { total-rewards-earned: (+ (get total-rewards-earned user-metrics) total-reward) })
    )

    (ok total-reward)
  )
)

;; Calculate platform success metrics
(define-public (calculate-platform-metrics (metric-type (string-ascii 30)) (period uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)

    ;; Simplified calculation - in reality would aggregate data
    (map-set platform-metrics
      { metric-type: metric-type, period: period }
      {
        value: u75, ;; Example success rate
        calculated-at: block-height,
        sample-size: u100
      }
    )

    (ok true)
  )
)

;; Private Functions

(define-private (calculate-milestone-score (milestone-type (string-ascii 30)))
  (if (is-eq milestone-type "first-date")
    u10
    (if (is-eq milestone-type "exclusive")
      u25
      (if (is-eq milestone-type "meeting-family")
        u40
        (if (is-eq milestone-type "engagement")
          u60
          (if (is-eq milestone-type "marriage")
            u100
            u5))))) ;; Default score
)

(define-private (calculate-bonus-multiplier (success-rate uint))
  (if (>= success-rate u90)
    u3
    (if (>= success-rate u75)
      u2
      (if (>= success-rate u60)
        u1
        u0)))
)

(define-private (update-user-relationship-count (user-id uint))
  (let
    (
      (current-metrics (default-to {
        total-relationships: u0,
        successful-relationships: u0,
        average-relationship-duration: u0,
        success-rate: u0,
        total-rewards-earned: u0,
        reputation-bonus: u0,
        last-calculated: u0
      } (map-get? user-success-metrics { user-id: user-id })))
    )
    (map-set user-success-metrics
      { user-id: user-id }
      (merge current-metrics {
        total-relationships: (+ (get total-relationships current-metrics) u1),
        last-calculated: block-height
      })
    )
  )
)

(define-private (calculate-final-success-score (relationship-id uint))
  (let
    (
      (relationship (unwrap-panic (map-get? relationships { relationship-id: relationship-id })))
      (duration (- block-height (get started-at relationship)))
      (duration-score (if (> duration u1440) u20 (/ (* duration u20) u1440))) ;; Max 20 points for 1+ days
      (milestone-score (get success-score relationship))
      (final-score (+ milestone-score duration-score))
    )
    (map-set relationships
      { relationship-id: relationship-id }
      (merge relationship { success-score: final-score })
    )
  )
)

(define-private (update-user-success-metrics (user-id uint) (relationship-id uint))
  (let
    (
      (relationship (unwrap-panic (map-get? relationships { relationship-id: relationship-id })))
      (current-metrics (unwrap-panic (map-get? user-success-metrics { user-id: user-id })))
      (is-successful (>= (get success-score relationship) u70))
      (new-successful-count (if is-successful
                              (+ (get successful-relationships current-metrics) u1)
                              (get successful-relationships current-metrics)))
      (new-success-rate (/ (* new-successful-count u100) (get total-relationships current-metrics)))
    )
    (map-set user-success-metrics
      { user-id: user-id }
      (merge current-metrics {
        successful-relationships: new-successful-count,
        success-rate: new-success-rate,
        last-calculated: block-height
      })
    )
  )
)

(define-private (distribute-milestone-reward (relationship-id uint) (milestone-type (string-ascii 30)))
  (let
    (
      (relationship (unwrap-panic (map-get? relationships { relationship-id: relationship-id })))
      (reward-amount (calculate-milestone-score milestone-type))
    )
    ;; In a real implementation, this would distribute actual rewards
    (ok true)
  )
)

;; Read-only Functions

(define-read-only (get-relationship (relationship-id uint))
  (map-get? relationships { relationship-id: relationship-id })
)

(define-read-only (get-relationship-milestone (relationship-id uint) (milestone-type (string-ascii 30)))
  (map-get? relationship-milestones { relationship-id: relationship-id, milestone-type: milestone-type })
)

(define-read-only (get-user-success-metrics (user-id uint))
  (map-get? user-success-metrics { user-id: user-id })
)

(define-read-only (get-platform-metrics (metric-type (string-ascii 30)) (period uint))
  (map-get? platform-metrics { metric-type: metric-type, period: period })
)

(define-read-only (get-success-reward (user-id uint) (relationship-id uint))
  (map-get? success-rewards { user-id: user-id, relationship-id: relationship-id })
)

(define-read-only (get-relationship-success-score (relationship-id uint))
  (match (map-get? relationships { relationship-id: relationship-id })
    relationship (get success-score relationship)
    u0
  )
)

(define-read-only (get-user-success-rate (user-id uint))
  (match (map-get? user-success-metrics { user-id: user-id })
    metrics (get success-rate metrics)
    u0
  )
)

(define-read-only (get-next-relationship-id)
  (var-get next-relationship-id)
)
