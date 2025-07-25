;; Transportation Cost Assistance Contract
;; Provides subsidized transportation vouchers for low-income individuals

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-INVALID-INPUT (err u201))
(define-constant ERR-INSUFFICIENT-FUNDS (err u202))
(define-constant ERR-NOT-ELIGIBLE (err u203))
(define-constant ERR-ALREADY-CLAIMED (err u204))

;; Data Variables
(define-data-var total-vouchers-issued uint u0)
(define-data-var total-funds-distributed uint u0)
(define-data-var voucher-value uint u50) ;; Default voucher value in microSTX

;; Data Maps
(define-map eligible-users
  { user: principal }
  {
    income-level: uint, ;; 1=very-low, 2=low, 3=moderate
    household-size: uint,
    disability-status: bool,
    verified-at: uint,
    is-active: bool
  }
)

(define-map vouchers
  { voucher-id: uint }
  {
    recipient: principal,
    amount: uint,
    transportation-type: (string-ascii 20), ;; "transit", "rideshare", "bike"
    issued-at: uint,
    expires-at: uint,
    is-used: bool,
    used-at: (optional uint)
  }
)

(define-map monthly-allocations
  { user: principal, month: uint, year: uint }
  {
    vouchers-claimed: uint,
    total-amount: uint,
    max-allowed: uint
  }
)

(define-map transportation-providers
  { provider: principal }
  {
    name: (string-ascii 50),
    transportation-type: (string-ascii 20),
    is-approved: bool,
    vouchers-redeemed: uint,
    total-redeemed-amount: uint
  }
)

;; Read-only functions
(define-read-only (get-user-eligibility (user principal))
  (map-get? eligible-users { user: user })
)

(define-read-only (get-voucher (voucher-id uint))
  (map-get? vouchers { voucher-id: voucher-id })
)

(define-read-only (get-monthly-allocation (user principal) (month uint) (year uint))
  (map-get? monthly-allocations { user: user, month: month, year: year })
)

(define-read-only (get-provider-info (provider principal))
  (map-get? transportation-providers { provider: provider })
)

(define-read-only (calculate-max-monthly-vouchers (income-level uint) (household-size uint) (has-disability bool))
  (let ((base-vouchers (if (is-eq income-level u1) u8 (if (is-eq income-level u2) u6 u4)))
        (household-bonus (if (> household-size u4) u2 (if (> household-size u2) u1 u0)))
        (disability-bonus (if has-disability u2 u0)))
    (+ base-vouchers household-bonus disability-bonus)
  )
)

(define-read-only (get-contract-stats)
  {
    total-vouchers-issued: (var-get total-vouchers-issued),
    total-funds-distributed: (var-get total-funds-distributed),
    current-voucher-value: (var-get voucher-value)
  }
)

;; Public functions
(define-public (register-eligible-user
  (user principal)
  (income-level uint)
  (household-size uint)
  (disability-status bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= income-level u1) (<= income-level u3)) ERR-INVALID-INPUT)
    (asserts! (> household-size u0) ERR-INVALID-INPUT)

    (map-set eligible-users
      { user: user }
      {
        income-level: income-level,
        household-size: household-size,
        disability-status: disability-status,
        verified-at: block-height,
        is-active: true
      }
    )
    (ok true)
  )
)

(define-public (register-transportation-provider
  (provider principal)
  (name (string-ascii 50))
  (transportation-type (string-ascii 20)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)

    (map-set transportation-providers
      { provider: provider }
      {
        name: name,
        transportation-type: transportation-type,
        is-approved: true,
        vouchers-redeemed: u0,
        total-redeemed-amount: u0
      }
    )
    (ok true)
  )
)

(define-public (claim-voucher (transportation-type (string-ascii 20)))
  (let ((user-eligibility (unwrap! (get-user-eligibility tx-sender) ERR-NOT-ELIGIBLE))
        (current-month (/ block-height u144)) ;; Approximate blocks per month
        (current-year (/ current-month u12))
        (voucher-id (+ (var-get total-vouchers-issued) u1)))

    (asserts! (get is-active user-eligibility) ERR-NOT-ELIGIBLE)

    (let ((max-vouchers (calculate-max-monthly-vouchers
                          (get income-level user-eligibility)
                          (get household-size user-eligibility)
                          (get disability-status user-eligibility)))
          (current-allocation (default-to
                               { vouchers-claimed: u0, total-amount: u0, max-allowed: max-vouchers }
                               (get-monthly-allocation tx-sender current-month current-year))))

      (asserts! (< (get vouchers-claimed current-allocation) max-vouchers) ERR-ALREADY-CLAIMED)

      ;; Create voucher
      (map-set vouchers
        { voucher-id: voucher-id }
        {
          recipient: tx-sender,
          amount: (var-get voucher-value),
          transportation-type: transportation-type,
          issued-at: block-height,
          expires-at: (+ block-height u4320), ;; ~30 days
          is-used: false,
          used-at: none
        }
      )

      ;; Update monthly allocation
      (map-set monthly-allocations
        { user: tx-sender, month: current-month, year: current-year }
        {
          vouchers-claimed: (+ (get vouchers-claimed current-allocation) u1),
          total-amount: (+ (get total-amount current-allocation) (var-get voucher-value)),
          max-allowed: max-vouchers
        }
      )

      ;; Update contract stats
      (var-set total-vouchers-issued voucher-id)
      (var-set total-funds-distributed (+ (var-get total-funds-distributed) (var-get voucher-value)))

      (ok voucher-id)
    )
  )
)

(define-public (redeem-voucher (voucher-id uint))
  (let ((voucher-data (unwrap! (get-voucher voucher-id) ERR-INVALID-INPUT))
        (provider-info (unwrap! (get-provider-info tx-sender) ERR-NOT-AUTHORIZED)))

    (asserts! (not (get is-used voucher-data)) ERR-ALREADY-CLAIMED)
    (asserts! (< block-height (get expires-at voucher-data)) ERR-INVALID-INPUT)
    (asserts! (get is-approved provider-info) ERR-NOT-AUTHORIZED)

    ;; Mark voucher as used
    (map-set vouchers
      { voucher-id: voucher-id }
      (merge voucher-data {
        is-used: true,
        used-at: (some block-height)
      })
    )

    ;; Update provider stats
    (map-set transportation-providers
      { provider: tx-sender }
      (merge provider-info {
        vouchers-redeemed: (+ (get vouchers-redeemed provider-info) u1),
        total-redeemed-amount: (+ (get total-redeemed-amount provider-info) (get amount voucher-data))
      })
    )

    (ok (get amount voucher-data))
  )
)

(define-public (update-voucher-value (new-value uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> new-value u0) ERR-INVALID-INPUT)

    (var-set voucher-value new-value)
    (ok true)
  )
)
