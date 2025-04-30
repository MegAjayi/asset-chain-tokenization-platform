;; =========================================================================
;; Asset Tokenizer - ChainMint Platform
;; =========================================================================
;; This contract manages the entire lifecycle of tokenized physical assets 
;; on the Stacks blockchain. It enables the creation, verification, transfer,
;; and management of tokens representing real-world assets such as real estate,
;; art, commodities, and collectibles.
;;
;; Each token contains comprehensive metadata about the physical asset,
;; verification status, and ownership information. The contract supports
;; fractional ownership and maintains an immutable audit trail of all
;; asset-related actions.
;; =========================================================================

;; =========================================================================
;; Error Constants
;; =========================================================================
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-NOT-OWNER (err u101))
(define-constant ERR-ASSET-NOT-FOUND (err u102))
(define-constant ERR-ASSET-ALREADY-EXISTS (err u103))
(define-constant ERR-INVALID-PERCENTAGE (err u104))
(define-constant ERR-TOTAL-PERCENTAGE-EXCEEDED (err u105))
(define-constant ERR-ASSET-RETIRED (err u106))
(define-constant ERR-NOT-VERIFIER (err u107))
(define-constant ERR-INVALID-PARAMS (err u108))
(define-constant ERR-TRANSFER-FAILED (err u109))
(define-constant ERR-INSUFFICIENT-OWNERSHIP (err u110))

;; =========================================================================
;; Data Maps & Variables
;; =========================================================================

;; Contract admin - has authority to add verifiers and manage the contract
(define-data-var contract-admin principal tx-sender)

;; Authorized verifiers who can validate assets
(define-map verifiers principal bool)

;; Asset metadata and verification status
(define-map assets
  { asset-id: uint }
  {
    name: (string-ascii 64),
    description: (string-utf8 500),
    asset-type: (string-ascii 32),
    location: (string-utf8 256),
    creation-time: uint,
    last-updated: uint,
    verification-status: (string-ascii 20),
    verified-by: (optional principal),
    verification-date: (optional uint),
    metadata-uri: (string-ascii 256),
    is-fractional: bool,
    is-retired: bool
  }
)

;; Ownership records for assets - maps asset ID to a map of owners and their percentage ownership
(define-map asset-ownership
  { asset-id: uint }
  { owners: (list 20 { owner: principal, percentage: uint }) }
)

;; Asset ID counter for issuing new assets
(define-data-var asset-id-counter uint u1)

;; Asset transfer history for audit trail
(define-map asset-transfers
  { asset-id: uint, transfer-id: uint }
  {
    from: principal,
    to: principal,
    percentage: uint,
    time: uint
  }
)

;; Transfer ID counter per asset
(define-map transfer-id-counters
  { asset-id: uint }
  { counter: uint }
)

;; =========================================================================
;; Private Functions
;; =========================================================================

;; Checks if the caller is the contract admin
(define-private (is-admin)
  (is-eq tx-sender (var-get contract-admin))
)

;; Checks if the caller is an authorized verifier
(define-private (is-verifier)
  (default-to false (map-get? verifiers tx-sender))
)

;; Gets the current transfer ID counter for an asset and increments it
(define-private (get-and-increment-transfer-id (asset-id uint))
  (let ((current-id (default-to { counter: u0 } (map-get? transfer-id-counters { asset-id: asset-id }))))
    (map-set transfer-id-counters 
      { asset-id: asset-id } 
      { counter: (+ u1 (get counter current-id)) })
    (get counter current-id)
  )
)

;; Gets the next asset ID and increments the counter
(define-private (get-and-increment-asset-id)
  (let ((current-id (var-get asset-id-counter)))
    (var-set asset-id-counter (+ current-id u1))
    current-id
  )
)

;; Validates ownership percentage
(define-private (is-valid-percentage (percentage uint))
  (and (> percentage u0) (<= percentage u10000))
)

;; Checks if sender owns at least the specified percentage of an asset
(define-private (owns-sufficient-percentage (sender principal) (asset-id uint) (percentage uint))
  (let (
    (ownership-data (default-to { owners: (list) } (map-get? asset-ownership { asset-id: asset-id })))
    (owners-list (get owners ownership-data))
    (owner-entry (filter (lambda (entry) (is-eq (get owner entry) sender)) owners-list))
  )
    (if (is-eq (len owner-entry) u0)
      false
      (>= (get percentage (element-at owner-entry u0)) percentage)
    )
  )
)

;; Updates ownership record after a transfer
(define-private (update-ownership-record (asset-id uint) (from principal) (to principal) (percentage uint))
  (let (
    (ownership-data (default-to { owners: (list) } (map-get? asset-ownership { asset-id: asset-id })))
    (current-owners-list (get owners ownership-data))
    
    ;; Find current owner entry
    (from-entry (filter (lambda (entry) (is-eq (get owner entry) from)) current-owners-list))
    (from-percentage (if (is-eq (len from-entry) u0) u0 (get percentage (element-at from-entry u0))))
    (from-new-percentage (- from-percentage percentage))
    
    ;; Find target owner entry if exists
    (to-entry (filter (lambda (entry) (is-eq (get owner entry) to)) current-owners-list))
    (to-percentage (if (is-eq (len to-entry) u0) u0 (get percentage (element-at to-entry u0))))
    (to-new-percentage (+ to-percentage percentage))
    
    ;; Remove both entries from the list to rebuild it
    (filtered-list (filter (lambda (entry) 
      (and 
        (not (is-eq (get owner entry) from)) 
        (not (is-eq (get owner entry) to))
      )) current-owners-list))
    
    ;; Add back entries with updated percentages
    (updated-list-step1 (if (> from-new-percentage u0)
      (append filtered-list (list { owner: from, percentage: from-new-percentage }))
      filtered-list))
    
    (updated-list (append updated-list-step1 (list { owner: to, percentage: to-new-percentage })))
  )
    (map-set asset-ownership { asset-id: asset-id } { owners: updated-list })
    (ok true)
  )
)

;; Records a transfer in the history log
(define-private (record-transfer (asset-id uint) (from principal) (to principal) (percentage uint))
  (let ((transfer-id (get-and-increment-transfer-id asset-id)))
    (map-set asset-transfers
      { asset-id: asset-id, transfer-id: transfer-id }
      {
        from: from,
        to: to,
        percentage: percentage,
        time: block-height
      }
    )
    (ok transfer-id)
  )
)

;; =========================================================================
;; Read-Only Functions
;; =========================================================================

;; Get asset details by ID
(define-read-only (get-asset (asset-id uint))
  (map-get? assets { asset-id: asset-id })
)

;; Get asset ownership information
(define-read-only (get-asset-ownership (asset-id uint))
  (map-get? asset-ownership { asset-id: asset-id })
)

;; Check if principal is an authorized verifier
(define-read-only (is-authorized-verifier (address principal))
  (default-to false (map-get? verifiers address))
)

;; Get the current contract admin
(define-read-only (get-contract-admin)
  (var-get contract-admin)
)

;; Get percentage ownership of a specific principal for an asset
(define-read-only (get-ownership-percentage (asset-id uint) (owner principal))
  (let (
    (ownership-data (default-to { owners: (list) } (map-get? asset-ownership { asset-id: asset-id })))
    (owners-list (get owners ownership-data))
    (owner-entry (filter (lambda (entry) (is-eq (get owner entry) owner)) owners-list))
  )
    (if (is-eq (len owner-entry) u0)
      u0
      (get percentage (element-at owner-entry u0))
    )
  )
)

;; Get the total number of assets
(define-read-only (get-asset-count)
  (- (var-get asset-id-counter) u1)
)

;; Get transfer details
(define-read-only (get-transfer-details (asset-id uint) (transfer-id uint))
  (map-get? asset-transfers { asset-id: asset-id, transfer-id: transfer-id })
)

;; =========================================================================
;; Public Functions
;; =========================================================================

;; Set a new contract admin (only current admin can call)
(define-public (set-contract-admin (new-admin principal))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (var-set contract-admin new-admin)
    (ok true)
  )
)

;; Add or remove authorized verifiers (only admin can call)
(define-public (set-verifier (verifier-address principal) (authorized bool))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (map-set verifiers verifier-address authorized)
    (ok true)
  )
)

;; Create a new asset token (only verifiers can call)
(define-public (create-asset (name (string-ascii 64)) 
                            (description (string-utf8 500))
                            (asset-type (string-ascii 32))
                            (location (string-utf8 256))
                            (metadata-uri (string-ascii 256))
                            (is-fractional bool)
                            (initial-owner principal))
  (let (
    (asset-id (get-and-increment-asset-id))
    (current-time block-height)
  )
    ;; Only authorized verifiers can create assets
    (asserts! (is-verifier) ERR-NOT-VERIFIER)
    
    ;; Create the asset record
    (map-set assets
      { asset-id: asset-id }
      {
        name: name,
        description: description,
        asset-type: asset-type,
        location: location,
        creation-time: current-time,
        last-updated: current-time,
        verification-status: "pending",
        verified-by: none,
        verification-date: none,
        metadata-uri: metadata-uri,
        is-fractional: is-fractional,
        is-retired: false
      }
    )
    
    ;; Set initial ownership
    (map-set asset-ownership
      { asset-id: asset-id }
      { owners: (list { owner: initial-owner, percentage: u10000 }) } ;; 100.00% ownership (10000 basis points)
    )
    
    ;; Initialize transfer counter
    (map-set transfer-id-counters { asset-id: asset-id } { counter: u0 })
    
    ;; Return the created asset ID
    (ok asset-id)
  )
)

;; Verify an existing asset (only verifiers can call)
(define-public (verify-asset (asset-id uint) (verification-status (string-ascii 20)))
  (let (
    (asset (default-to false (map-get? assets { asset-id: asset-id })))
    (current-time block-height)
  )
    ;; Check if asset exists and caller is authorized
    (asserts! asset ERR-ASSET-NOT-FOUND)
    (asserts! (is-verifier) ERR-NOT-VERIFIER)
    
    ;; Update verification status
    (map-set assets
      { asset-id: asset-id }
      (merge asset {
        verification-status: verification-status,
        verified-by: (some tx-sender),
        verification-date: (some current-time),
        last-updated: current-time
      })
    )
    
    (ok true)
  )
)

;; Update asset metadata (only verifiers can call)
(define-public (update-asset-metadata (asset-id uint)
                                     (name (optional (string-ascii 64)))
                                     (description (optional (string-utf8 500)))
                                     (location (optional (string-utf8 256)))
                                     (metadata-uri (optional (string-ascii 256))))
  (let (
    (asset (default-to false (map-get? assets { asset-id: asset-id })))
    (current-time block-height)
  )
    ;; Check if asset exists and caller is authorized
    (asserts! asset ERR-ASSET-NOT-FOUND)
    (asserts! (is-verifier) ERR-NOT-VERIFIER)
    (asserts! (not (get is-retired asset)) ERR-ASSET-RETIRED)
    
    ;; Update the asset with new metadata
    (map-set assets
      { asset-id: asset-id }
      (merge asset {
        name: (default-to (get name asset) name),
        description: (default-to (get description asset) description),
        location: (default-to (get location asset) location),
        metadata-uri: (default-to (get metadata-uri asset) metadata-uri),
        last-updated: current-time
      })
    )
    
    (ok true)
  )
)

;; Transfer full ownership of an asset (owner-only function)
(define-public (transfer-asset (asset-id uint) (recipient principal))
  (let (
    (asset (default-to false (map-get? assets { asset-id: asset-id })))
  )
    ;; Basic checks
    (asserts! asset ERR-ASSET-NOT-FOUND)
    (asserts! (not (get is-retired asset)) ERR-ASSET-RETIRED)
    (asserts! (not (get is-fractional asset)) ERR-INVALID-PARAMS)
    (asserts! (owns-sufficient-percentage tx-sender asset-id u10000) ERR-NOT-OWNER)
    
    ;; Perform the transfer
    (try! (update-ownership-record asset-id tx-sender recipient u10000))
    (try! (record-transfer asset-id tx-sender recipient u10000))
    
    (ok true)
  )
)

;; Transfer partial ownership of a fractional asset
(define-public (transfer-fractional (asset-id uint) (recipient principal) (percentage uint))
  (let (
    (asset (default-to false (map-get? assets { asset-id: asset-id })))
  )
    ;; Basic checks
    (asserts! asset ERR-ASSET-NOT-FOUND)
    (asserts! (not (get is-retired asset)) ERR-ASSET-RETIRED)
    (asserts! (get is-fractional asset) ERR-INVALID-PARAMS)
    (asserts! (is-valid-percentage percentage) ERR-INVALID-PERCENTAGE)
    (asserts! (owns-sufficient-percentage tx-sender asset-id percentage) ERR-INSUFFICIENT-OWNERSHIP)
    
    ;; Perform the transfer
    (try! (update-ownership-record asset-id tx-sender recipient percentage))
    (try! (record-transfer asset-id tx-sender recipient percentage))
    
    (ok true)
  )
)

;; Retire an asset (admin or verifier only)
(define-public (retire-asset (asset-id uint))
  (let (
    (asset (default-to false (map-get? assets { asset-id: asset-id })))
  )
    ;; Basic checks
    (asserts! asset ERR-ASSET-NOT-FOUND)
    (asserts! (or (is-admin) (is-verifier)) ERR-NOT-AUTHORIZED)
    (asserts! (not (get is-retired asset)) ERR-ASSET-RETIRED)
    
    ;; Mark the asset as retired
    (map-set assets
      { asset-id: asset-id }
      (merge asset {
        is-retired: true,
        last-updated: block-height
      })
    )
    
    (ok true)
  )
)

;; Convert a non-fractional asset to fractional (verifier only)
(define-public (convert-to-fractional (asset-id uint))
  (let (
    (asset (default-to false (map-get? assets { asset-id: asset-id })))
  )
    ;; Basic checks
    (asserts! asset ERR-ASSET-NOT-FOUND)
    (asserts! (is-verifier) ERR-NOT-VERIFIER)
    (asserts! (not (get is-retired asset)) ERR-ASSET-RETIRED)
    (asserts! (not (get is-fractional asset)) ERR-INVALID-PARAMS)
    
    ;; Update the asset to be fractional
    (map-set assets
      { asset-id: asset-id }
      (merge asset {
        is-fractional: true,
        last-updated: block-height
      })
    )
    
    (ok true)
  )
)