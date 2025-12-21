# fibonacci

find the largest f(n) in exactly 1 second using o(log n) ring exponentiation with fft acceleration.

## overview

this app computes fibonacci numbers sequentially (f(1), f(2), f(3), ...) using ultra-fast o(log n) ℤ[√5] ring exponentiation, stopping when a single computation takes ≥ 1000ms. the goal is to find the highest possible n where f(n) can be computed within that time budget.

each f(n) is computed from scratch using binary exponentiation in the ℤ[√5] ring, accelerated with fft-based multiplication for large numbers. the result is a real-time graph showing how computation time grows exponentially as n increases.

## how it works

1. press **run f(n)** to start the computation
2. the app computes f(1), f(2), f(3), ... sequentially, each from scratch
3. each computation uses o(log n) ring exponentiation (fast binary powering)
4. computation time is measured for each f(n)
5. when a single computation takes ≥ 1000ms, the loop stops
6. the last successfully computed f(n) is displayed as the result
7. a real-time graph shows computation time vs n (logarithmic axes)

## the algorithm

### sequential computation loop

the core computation loop in `runPurePowering()`:

```swift
var n: UInt64 = 1
while true {
    let compStart = clock.now
    let fib = fibonacci(n: n)  // O(log n) ring exponentiation
    let compTimeMs = measure(compStart)
    
    if compTimeMs >= 1000.0 {
        break  // This computation took too long, n-1 was the last valid
    }
    
    storeResult(n, compTimeMs)
    n += 1
}
```

each f(n) is computed independently using binary exponentiation in the ℤ[√5] ring. there's no memoization or reuse—each computation starts from the base elements.

### ℤ[√5] ring exponentiation

the `fibonacci(n:)` function uses o(log n) binary exponentiation:

```swift
func fibonacci(n: UInt64) -> BigInt {
    if n <= 2 { return BigInt(1) }
    
    var step = Zrt5(1, 1)  // represents φ²
    var fib = Zrt5(1, 1)   // initial result
    var exp = n - 1
    
    while exp > 0 {
        if (exp & 1) != 0 {
            fib = fib.multiply(step)
            fib.rightShift(1)  // normalization
        }
        step = step.square()
        step.rightShift(1)  // normalization
        exp >>= 1
    }
    
    return fib.b  // F(n) is the √5 coefficient
}
```

this is mathematically equivalent to computing φ^n in the ring ℤ[√5] = {a + b√5 | a, b ∈ ℤ}, where φ = (1 + √5)/2 is the golden ratio.

### zrt5 ring structure

**`Zrt5` struct**: represents element `a + b√5` in ℤ[√5]
- `multiply(_:)`: multiplies two ring elements
  - formula: `(a + b√5)(c + d√5) = (ac + 5bd) + (ad + bc)√5`
  - uses fft-accelerated multiplication for large operands
  - optimization: `5bd = (bd << 2) + bd` (bit shift + add instead of multiply)
- `square()`: optimized squaring
  - formula: `(a + b√5)² = (a² + 5b²) + 2ab√5`
  - requires 3 multiplications (a², b², ab)
  - uses fft for large operands
- `rightShift(_:)`: divides by 2^n (normalization after each operation)

### fft-accelerated multiplication

**`FFTMultiplier`**: provides fft-based multiplication for large bigint operations

**threshold**: uses fft if:
- multiplication: combined bit width > 192 bits
- squaring: bit width > 96 bits
- otherwise falls back to standard bigint multiplication

**base-2^15 digit representation**:
- each digit represents 15 bits (base = 32768)
- safe for double precision (< 2^53)
- enables efficient fft convolution

**magnitude conversion (o(n))**:
- `magnitudeToDigits()`: converts bigint magnitude to base-2^15 digits
  - directly accesses `magnitude.words: [UInt]` (no string conversion)
  - uses bit manipulation (shifts and masks) for o(n) conversion
- `digitsToMagnitude()`: converts digits back to bigint
  - builds `[UInt]` words directly from digits
  - uses `BigUInt(words:)` constructor for o(n) conversion

**fft convolution**:
- uses complex fft (`vDSP_fft_zipD`) for convolution
- forward fft on both operands
- pointwise complex multiplication (`vDSP_zvmulD`)
- inverse fft
- scales by 1/n and extracts result with carry propagation

**vectorized squaring**:
- single forward fft
- vectorized complex square using vdsp:
  - `vDSP_vmulD` for ar² and ai²
  - `vDSP_vsubD` for (ar² - ai²)
  - `vDSP_vsmulD` for 2*ar*ai
- inverse fft and result extraction

## architecture

### decoupled computation and ui updates

the app uses a **decoupled architecture** to ensure computation runs at full speed without blocking ui updates:

**computation thread** (`runPurePowering()`):
- runs `nonisolated async` on a background task
- computes f(n) sequentially, measuring each computation time
- stores results in thread-safe storage (`nonisolated` properties protected by `DispatchQueue`)
- never blocks on mainactor—computation runs at maximum speed

**ui update timer** (`startUIUpdateTimer()`):
- separate `Task` running on `@MainActor`
- polls thread-safe storage every ~33ms (~30fps)
- updates `@Observable` properties to trigger swiftui updates
- generates graph points from computation history

**thread-safe storage**:
- `_latestN`, `_latestTimeMs`, `_latestTotalElapsed`, `_latestFib` (all `nonisolated`)
- `_computationHistory` array storing all (n, timeMs, timestamp) entries
- protected by `DispatchQueue` with barriers for thread safety
- computed properties (`latestN`, etc.) provide safe read/write access

this architecture ensures:
- computation runs unhindered at maximum speed
- ui updates smoothly in real-time without blocking
- no performance penalty from ui updates

### graph visualization

**real-time graph**: shows computation time vs n with logarithmic axes
- x-axis: n (logarithmic scale)
- y-axis: computation time in milliseconds (logarithmic scale)
- data points: sampled from computation history (max 2000 points for performance)
- updates every ~33ms during computation

the graph clearly shows the exponential growth in computation time as n increases.

## major files

### FibonacciViewModel.swift

**`start()`**: initiates the computation
- resets state
- starts ui update timer
- launches computation task on background thread

**`runPurePowering()`**: main computation loop
- computes f(1), f(2), f(3), ... sequentially
- measures computation time for each
- stops when a single computation takes ≥ 1000ms
- stores results in thread-safe storage
- finalizes results on mainactor

**`fibonacci(n:)`**: o(log n) ring exponentiation
- pure binary exponentiation in ℤ[√5] ring
- no memoization, each computation is independent

**`startUIUpdateTimer()`**: ui update loop
- runs on mainactor
- polls thread-safe storage every 33ms
- updates observable properties
- generates graph data from computation history

### Zrt5.swift

**`Zrt5` struct**: ring element `a + b√5`
- `multiply(_:)`: ring multiplication with fft acceleration
- `square()`: optimized squaring (3 multiplies)
- `rightShift(_:)`: normalization by powers of 2

**`fibonacciInterruptible()`**: (not currently used)
- this function exists but is not called by the viewmodel
- it was designed for a different approach (interruptible single-pass computation)
- the current implementation uses sequential computation instead

### FFTMultiplier.swift

**`multiply(_:_:)`**: fft-accelerated multiplication
- converts bigint magnitudes to base-2^15 digits
- performs fft convolution for large operands
- extracts result with carry propagation
- falls back to standard multiply for small operands

**`square(_:)`**: optimized fft squaring
- single forward fft
- vectorized complex square
- inverse fft and result extraction

**`magnitudeToDigits(_:)`**: o(n) conversion
- direct access to `magnitude.words`
- bit manipulation for efficient conversion

**`digitsToMagnitude(_:)`**: o(n) conversion
- builds words array directly
- uses `BigUInt(words:)` constructor

### ContentView.swift

**ui states**:
- `.idle`: shows title, algorithm info, "run f(n)" button
- `.running`: shows progress ring, current n, real-time graph
- `.completed`: shows final results, graph, number preview, "run again" button

**graph card**: displays computation time vs n
- logarithmic axes for exponential visualization
- updates in real-time during computation
- scientific notation for large n values

**glassmorphic design**: modern "liquid glass" aesthetic
- `ultraThinMaterial` backgrounds
- subtle blur and vibrancy
- rounded corners and shadows
- dark mode optimized

## performance characteristics

### time complexity

- **each f(n)**: o(log n) multiplications/squarings
- **with fft**: each multiplication/squaring is o(n log n) where n is the number of digits
- **overall**: as n grows, digit count grows linearly (log10(f(n)) ≈ n * 0.209), so computation time grows roughly o(n log² n) per f(n)

### expected results

on apple silicon (m3 max, m1/m2, a17 pro):

| device | typical max n | digits | computation time |
|--------|---------------|--------|------------------|
| m3 max | 5,000 - 10,000 | ~1,000 - 2,000 | ~1000ms for last f(n) |
| m1/m2 | 3,000 - 7,000 | ~600 - 1,400 | ~1000ms for last f(n) |
| a17 pro | 2,000 - 5,000 | ~400 - 1,000 | ~1000ms for last f(n) |

note: these are rough estimates. actual results depend on:
- fft threshold triggering point
- memory bandwidth
- cpu thermal throttling
- system load

### why sequential computation?

the sequential approach (computing f(1), f(2), f(3), ...) has several advantages:
- **simple stopping condition**: stop when one computation takes too long
- **smooth graph**: continuous data points for visualization
- **predictable behavior**: no complex prediction or probing logic
- **honest benchmark**: true one-shot computation with no pre-calibration

each f(n) is computed independently, so there's no reuse or memoization—this is a pure benchmark of the computation speed.

## requirements

- **xcode**: 16.0+
- **swift**: 5.9+
- **platforms**: ios 17.0+ / macos 14.0+
- **dependencies**:
  - `leif-ibsen/BigInt` (via swift package manager)
  - `Accelerate` framework (built-in, for fft)

## setup

1. open `fibonacci.xcodeproj` in xcode
2. bigint package will resolve automatically via spm
3. build and run (⌘R)
4. press "run f(n)" to start the computation

## project structure

```
fibonacci/
├── fibonacci/
│   ├── fibonacciApp.swift       # app entry point
│   ├── ContentView.swift        # swiftui ui with real-time graph
│   ├── FibonacciViewModel.swift # computation controller, state management
│   ├── Zrt5.swift               # ℤ[√5] ring exponentiation
│   └── FFTMultiplier.swift      # fft-accelerated bigint multiplication
└── fibonacci.xcodeproj/
```

## technical notes

### why ℤ[√5] ring?

the fibonacci sequence has a closed-form expression using the golden ratio:
- f(n) = (φⁿ - ψⁿ) / √5, where φ = (1 + √5)/2 and ψ = (1 - √5)/2

computing in the ring ℤ[√5] = {a + b√5 | a, b ∈ ℤ} allows exact integer arithmetic while leveraging this structure. the ring exponentiation computes φⁿ in the ring, and f(n) is extracted as the √5 coefficient.

### fft base choice (2^15)

base-2^15 (32768) was chosen because:
- fits comfortably in double precision (< 2^53)
- allows efficient bit manipulation conversion
- balances fft size vs precision
- each digit represents 15 bits, reducing fft array size

### thread safety

the decoupled architecture requires careful thread safety:
- `@MainActor` on viewmodel ensures ui properties are main-actor isolated
- `nonisolated` properties for thread-safe storage
- `DispatchQueue` with barriers for atomic updates
- computed properties provide safe access from any thread

this allows the computation to run at maximum speed while ui updates smoothly.

## license

see project license file for details.
