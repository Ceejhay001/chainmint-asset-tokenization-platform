;; chainmint-core
;; This contract serves as the central registry for all tokenized physical assets on ChainMint,
;; enabling asset owners to register physical assets, verifiers to provide attestations,
;; and handling the issuance of ownership tokens (fungible or non-fungible).

;; =================================
;; Error Constants
;; =================================
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ASSET-NOT-FOUND (err u101))
(define-constant ERR-ASSET-ALREADY-EXISTS (err u102))
(define-constant ERR-VERIFIER-NOT-APPROVED (err u103))
(define-constant ERR-ASSET-NOT-VERIFIED (err u104))
(define-constant ERR-INVALID-AMOUNT (err u105))
(define-constant ERR-INSUFFICIENT-OWNERSHIP (err u106))
(define-constant ERR-ASSET-LOCKED (err u107))
(define-constant ERR-INVALID-ASSET-TYPE (err u108))
(define-constant ERR-VERIFICATION-EXPIRED (err u109))
(define-constant ERR-ASSET-FROZEN (err u110))

;; =================================
;; Data Definitions
;; =================================

;; Contract administration
(define-data-var contract-owner principal tx-sender)
(define-map approved-verifiers principal bool)

;; Asset types
(define-constant ASSET-TYPE-INDIVISIBLE u1)  ;; For unique assets like art or collectibles
(define-constant ASSET-TYPE-DIVISIBLE u2)    ;; For divisible assets like real estate

;; Verification statuses
(define-constant VERIFICATION-STATUS-PENDING u1)
(define-constant VERIFICATION-STATUS-VERIFIED u2)
(define-constant VERIFICATION-STATUS-REJECTED u3)

;; Asset registry - stores metadata about each tokenized asset
(define-map asset-registry
  { asset-id: uint }
  {
    creator: principal,
    asset-type: uint,
    asset-name: (string-ascii 100),
    description: (string-utf8 500),
    creation-time: uint,
    verification-status: uint,
    is-locked: bool,
    is-frozen: bool,
    physical-doc-uri: (optional (string-utf8 256)),
    total-supply: uint,  ;; For divisible assets - how many tokens represent 100% ownership
    royalty-rate: uint,  ;; Basis points (e.g., 250 = 2.5%)
    last-appraisal-value: (optional uint)
  }
)

;; Asset ownership - tracks ownership for divisible assets
(define-map asset-ownership
  { asset-id: uint, owner: principal }
  { share-amount: uint }
)

;; Verification details - stores attestations from verifiers
(define-map verification-records
  { asset-id: uint, verifier: principal }
  {
    verification-time: uint,
    verification-expiry: uint,
    verification-notes: (string-utf8 500),
    appraised-value: (optional uint)
  }
)

;; Counter for asset IDs
(define-data-var next-asset-id uint u1)

;; =================================
;; Private Functions
;; =================================

;; Check if principal is contract owner
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner))
)

;; Check if principal is an approved verifier
(define-private (is-approved-verifier (verifier principal))
  (default-to false (map-get? approved-verifiers verifier))
)

;; Check if principal is the asset creator
(define-private (is-asset-creator (asset-id uint))
  (let ((asset (map-get? asset-registry { asset-id: asset-id })))
    (and 
      (is-some asset)
      (is-eq tx-sender (get creator (unwrap-panic asset)))
    )
  )
)

;; Check if the asset exists
(define-private (asset-exists (asset-id uint))
  (is-some (map-get? asset-registry { asset-id: asset-id }))
)

;; Check if the asset is not locked or frozen
(define-private (asset-available (asset-id uint))
  (let ((asset (map-get? asset-registry { asset-id: asset-id })))
    (if (is-none asset)
      false
      (let ((asset-data (unwrap-panic asset)))
        (and 
          (not (get is-locked asset-data))
          (not (get is-frozen asset-data))
        )
      )
    )
  )
)

;; Get principal's ownership share of an asset
(define-private (get-ownership-share (asset-id uint) (owner principal))
  (let ((ownership (map-get? asset-ownership { asset-id: asset-id, owner: owner })))
    (default-to u0 (match ownership ownership-data (some (get share-amount ownership-data)) none u0))
  )
)

;; Calculate if principal has sufficient ownership for a transfer
(define-private (has-sufficient-ownership (asset-id uint) (owner principal) (amount uint))
  (>= (get-ownership-share asset-id owner) amount)
)

;; Generate a new asset ID
(define-private (generate-asset-id)
  (let ((asset-id (var-get next-asset-id)))
    (var-set next-asset-id (+ asset-id u1))
    asset-id
  )
)

;; =================================
;; Read-Only Functions
;; =================================

;; Get asset details by ID
(define-read-only (get-asset (asset-id uint))
  (map-get? asset-registry { asset-id: asset-id })
)

;; Get verification details for an asset from a specific verifier
(define-read-only (get-verification (asset-id uint) (verifier principal))
  (map-get? verification-records { asset-id: asset-id, verifier: verifier })
)

;; Check if a principal is an approved verifier
(define-read-only (check-verifier-status (verifier principal))
  (is-approved-verifier verifier)
)

;; Get ownership details for a principal and asset
(define-read-only (get-principal-ownership (asset-id uint) (owner principal))
  (map-get? asset-ownership { asset-id: asset-id, owner: owner })
)

;; Calculate total percentage ownership for a principal (in basis points, 10000 = 100%)
(define-read-only (get-ownership-percentage (asset-id uint) (owner principal))
  (let (
    (asset (map-get? asset-registry { asset-id: asset-id }))
    (ownership (get-ownership-share asset-id owner))
  )
    (if (is-none asset)
      u0
      (let ((total-supply (get total-supply (unwrap-panic asset))))
        (if (is-eq total-supply u0)
          u0
          (/ (* ownership u10000) total-supply)
        )
      )
    )
  )
)

;; =================================
;; Public Functions
;; =================================

;; Initialize or update contract owner
(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (ok (var-set contract-owner new-owner))
  )
)

;; Add or remove an approved verifier
(define-public (set-verifier-status (verifier principal) (approved bool))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (ok (map-set approved-verifiers verifier approved))
  )
)

;; Register a new asset
(define-public (register-asset (asset-type uint) (asset-name (string-ascii 100)) (description (string-utf8 500)) (physical-doc-uri (optional (string-utf8 256))) (total-supply uint) (royalty-rate uint))
  (let ((asset-id (generate-asset-id)))
    (asserts! (or (is-eq asset-type ASSET-TYPE-INDIVISIBLE) (is-eq asset-type ASSET-TYPE-DIVISIBLE)) ERR-INVALID-ASSET-TYPE)
    
    ;; For divisible assets, total supply must be > 0
    (asserts! (or (is-eq asset-type ASSET-TYPE-INDIVISIBLE) (> total-supply u0)) ERR-INVALID-AMOUNT)
    
    ;; Royalty rate must be <= 10000 (100%)
    (asserts! (<= royalty-rate u10000) ERR-INVALID-AMOUNT)
    
    ;; Create the asset record
    (map-set asset-registry
      { asset-id: asset-id }
      {
        creator: tx-sender,
        asset-type: asset-type,
        asset-name: asset-name,
        description: description,
        creation-time: block-height,
        verification-status: VERIFICATION-STATUS-PENDING,
        is-locked: false,
        is-frozen: false,
        physical-doc-uri: physical-doc-uri,
        total-supply: total-supply,
        royalty-rate: royalty-rate,
        last-appraisal-value: none
      }
    )
    
    ;; For divisible assets, assign all tokens to the creator
    (if (is-eq asset-type ASSET-TYPE-DIVISIBLE)
      (map-set asset-ownership
        { asset-id: asset-id, owner: tx-sender }
        { share-amount: total-supply }
      )
      true
    )
    
    (ok asset-id)
  )
)

;; Update asset details - only allowed by the asset creator
(define-public (update-asset-details (asset-id uint) (asset-name (string-ascii 100)) (description (string-utf8 500)) (physical-doc-uri (optional (string-utf8 256))) (royalty-rate uint))
  (let ((asset (map-get? asset-registry { asset-id: asset-id })))
    (asserts! (is-some asset) ERR-ASSET-NOT-FOUND)
    (asserts! (is-asset-creator asset-id) ERR-NOT-AUTHORIZED)
    (asserts! (asset-available asset-id) ERR-ASSET-LOCKED)
    (asserts! (<= royalty-rate u10000) ERR-INVALID-AMOUNT)
    
    (let ((asset-data (unwrap-panic asset)))
      (ok (map-set asset-registry
        { asset-id: asset-id }
        (merge asset-data {
          asset-name: asset-name,
          description: description,
          physical-doc-uri: physical-doc-uri,
          royalty-rate: royalty-rate
        })
      ))
    )
  )
)

;; Verify an asset - only callable by approved verifiers
(define-public (verify-asset (asset-id uint) (verification-notes (string-utf8 500)) (appraised-value (optional uint)) (verification-expiry uint))
  (let ((asset (map-get? asset-registry { asset-id: asset-id })))
    (asserts! (is-some asset) ERR-ASSET-NOT-FOUND)
    (asserts! (is-approved-verifier tx-sender) ERR-VERIFIER-NOT-APPROVED)
    (asserts! (>= verification-expiry block-height) ERR-VERIFICATION-EXPIRED)
    
    ;; Record the verification
    (map-set verification-records
      { asset-id: asset-id, verifier: tx-sender }
      {
        verification-time: block-height,
        verification-expiry: verification-expiry,
        verification-notes: verification-notes,
        appraised-value: appraised-value
      }
    )
    
    ;; Update the asset status to verified
    (let ((asset-data (unwrap-panic asset)))
      (ok (map-set asset-registry
        { asset-id: asset-id }
        (merge asset-data {
          verification-status: VERIFICATION-STATUS-VERIFIED,
          last-appraisal-value: appraised-value
        })
      ))
    )
  )
)

;; Reject asset verification - only callable by approved verifiers
(define-public (reject-verification (asset-id uint) (verification-notes (string-utf8 500)))
  (let ((asset (map-get? asset-registry { asset-id: asset-id })))
    (asserts! (is-some asset) ERR-ASSET-NOT-FOUND)
    (asserts! (is-approved-verifier tx-sender) ERR-VERIFIER-NOT-APPROVED)
    
    ;; Record the verification rejection
    (map-set verification-records
      { asset-id: asset-id, verifier: tx-sender }
      {
        verification-time: block-height,
        verification-expiry: u0,  ;; Expiry 0 indicates rejection
        verification-notes: verification-notes,
        appraised-value: none
      }
    )
    
    ;; Update the asset status to rejected
    (let ((asset-data (unwrap-panic asset)))
      (ok (map-set asset-registry
        { asset-id: asset-id }
        (merge asset-data {
          verification-status: VERIFICATION-STATUS-REJECTED
        })
      ))
    )
  )
)

;; Transfer ownership shares - for divisible assets
(define-public (transfer-shares (asset-id uint) (recipient principal) (share-amount uint))
  (let (
    (asset (map-get? asset-registry { asset-id: asset-id }))
    (sender-shares (get-ownership-share asset-id tx-sender))
    (recipient-shares (get-ownership-share asset-id recipient))
  )
    (asserts! (is-some asset) ERR-ASSET-NOT-FOUND)
    (asserts! (is-eq (get asset-type (unwrap-panic asset)) ASSET-TYPE-DIVISIBLE) ERR-INVALID-ASSET-TYPE)
    (asserts! (asset-available asset-id) ERR-ASSET-LOCKED)
    (asserts! (is-eq (get verification-status (unwrap-panic asset)) VERIFICATION-STATUS-VERIFIED) ERR-ASSET-NOT-VERIFIED)
    (asserts! (> share-amount u0) ERR-INVALID-AMOUNT)
    (asserts! (has-sufficient-ownership asset-id tx-sender share-amount) ERR-INSUFFICIENT-OWNERSHIP)
    
    ;; Update sender's ownership
    (map-set asset-ownership
      { asset-id: asset-id, owner: tx-sender }
      { share-amount: (- sender-shares share-amount) }
    )
    
    ;; Update recipient's ownership
    (map-set asset-ownership
      { asset-id: asset-id, owner: recipient }
      { share-amount: (+ recipient-shares share-amount) }
    )
    
    (ok true)
  )
)

;; Transfer full ownership - for indivisible assets
(define-public (transfer-asset (asset-id uint) (recipient principal))
  (let ((asset (map-get? asset-registry { asset-id: asset-id })))
    (asserts! (is-some asset) ERR-ASSET-NOT-FOUND)
    (asserts! (is-eq (get asset-type (unwrap-panic asset)) ASSET-TYPE-INDIVISIBLE) ERR-INVALID-ASSET-TYPE)
    (asserts! (is-eq (get creator (unwrap-panic asset)) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (asset-available asset-id) ERR-ASSET-LOCKED)
    (asserts! (is-eq (get verification-status (unwrap-panic asset)) VERIFICATION-STATUS-VERIFIED) ERR-ASSET-NOT-VERIFIED)
    
    ;; Update asset creator
    (let ((asset-data (unwrap-panic asset)))
      (ok (map-set asset-registry
        { asset-id: asset-id }
        (merge asset-data { creator: recipient })
      ))
    )
  )
)

;; Lock or unlock an asset - only allowed by the asset creator
(define-public (set-asset-lock (asset-id uint) (locked bool))
  (let ((asset (map-get? asset-registry { asset-id: asset-id })))
    (asserts! (is-some asset) ERR-ASSET-NOT-FOUND)
    (asserts! (is-asset-creator asset-id) ERR-NOT-AUTHORIZED)
    
    (let ((asset-data (unwrap-panic asset)))
      (ok (map-set asset-registry
        { asset-id: asset-id }
        (merge asset-data { is-locked: locked })
      ))
    )
  )
)

;; Freeze or unfreeze an asset - only allowed by the contract owner
(define-public (set-asset-freeze (asset-id uint) (frozen bool))
  (let ((asset (map-get? asset-registry { asset-id: asset-id })))
    (asserts! (is-some asset) ERR-ASSET-NOT-FOUND)
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    
    (let ((asset-data (unwrap-panic asset)))
      (ok (map-set asset-registry
        { asset-id: asset-id }
        (merge asset-data { is-frozen: frozen })
      ))
    )
  )
)

;; Distribute revenue for a divisible asset
(define-public (distribute-revenue (asset-id uint) (revenue-amount uint))
  (let ((asset (map-get? asset-registry { asset-id: asset-id })))
    (asserts! (is-some asset) ERR-ASSET-NOT-FOUND)
    (asserts! (is-asset-creator asset-id) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get asset-type (unwrap-panic asset)) ASSET-TYPE-DIVISIBLE) ERR-INVALID-ASSET-TYPE)
    (asserts! (> revenue-amount u0) ERR-INVALID-AMOUNT)
    
    ;; Logic for distributing revenue would involve integrating with a token contract
    ;; or payment system - here we just return OK to indicate the function was called
    (ok true)
  )
)