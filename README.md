# derandomizer

A deliberately honest machine for finding *apparent* meaning in `/dev/urandom`.

It does not recover hidden messages. It searches many windows and interpretations,
scores them for English-like structure, subtracts a complexity penalty for more
aggressive decoders, and prints every new all-time best candidate.

```text
/dev/urandom
    |
    +-- raw
    +-- XOR byte key
    +-- additive byte key
    +-- forced 64-character alphabet (heavily penalized)
    |
    v
weighted scorer set(candidate) - decoder_cost
    |
    +-- language
    +-- compression
    +-- future local scorers
    |
    v
new all-time best? -> print it
```

## Run

```sh
odin run . -o:speed
```

or:

```sh
just run
```

The English-like `language` scorer remains the default. Select another scorer or
combine scorers with positive weights:

```sh
just run --scorer compression
just run --scorer language=1,compression=0.25
just run --scorer language=1,compression=0.25 --explain
```

`--explain` adds a scorer-owned breakdown beneath every new all-time best. It
shows each raw score, weight, weighted contribution, and the decoder cost.
`language` reports byte/shape/fragment evidence; `compression` reports raw and
encoded bit estimates plus the matches it found. Explanations are recomputed
only for candidates that are printed, so enabling them does not add work to the
hot scan loop.

Scanning uses all detected logical CPU threads by default. Set an explicit
worker count when benchmarking or reproducing a run:

```sh
just run --threads 4
just run --threads 1 # deterministic sequential baseline
```

`--threads 0` also selects automatic CPU detection. Work is split into coarse,
contiguous window ranges rather than one task per candidate. Every task owns its
scorer state, and the coordinator merges task-local records in input order, so
parallel and sequential scans produce the same record sequence for the same
bytes. A 40-byte carry preserves windows that cross read boundaries.

`compression` is an allocation-free LZSS bit-cost estimator. Its score is the
estimated number of bits saved relative to the candidate's raw bytes; random
literal-only data therefore receives a small negative score. `language` retains
the original heuristic's arbitrary point scale, so combination weights are also
the calibration between those two units.

Scorers declare which constant-byte transforms cannot change their underlying
signal. `compression` declares XOR and modular ADD invariant, so a
compression-only run evaluates two candidates per window (Raw and
`Alphabet64`) instead of all 512. `Alphabet64` remains because its lossy mapping
can genuinely change byte equality. A weighted scorer set keeps a decoder
family whenever any active scorer needs it, so adding `language` restores the
full XOR and ADD search.

## Adding a scorer

A scorer is a name, a state pointer, a score procedure, and an optional
explanation procedure. The hot-path score has this shape:

```odin
Score_Proc :: #type proc(state: rawptr, data: []u8) -> f64
```

An explainer writes human-readable evidence and returns the same raw score:

```odin
Explain_Proc :: #type proc(
    state: rawptr,
    data: []u8,
    weight: f64,
    writer: io.Writer,
) -> f64
```

Add scorer state to `Scorer_Registry`, register the procedures in
`lookup_scorer`, and the CLI parser and weighted composition will handle it
without changes to the scan or decoder loops. Set `Scorer.invariances` only for
transforms that conceptually preserve the scorer's signal; the scanner uses the
intersection across active scorers when pruning decoder families. Each parallel
scan task gets a separate registry, so mutable scratch state is safe but large
read-only models should eventually be shared. Scorers run in the hot loop, so
they should avoid allocation. Explainers run only when a record is printed.
Expensive tokenizer, local-LM, executable, image, and music scorers will need a
cheap prefilter or staged scoring pipeline before being added.

Run the finite built-in checks with:

```sh
just test
```
