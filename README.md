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
```

`compression` is an allocation-free LZSS bit-cost estimator. Its score is the
estimated number of bits saved relative to the candidate's raw bytes; random
literal-only data therefore receives a small negative score. `language` retains
the original heuristic's arbitrary point scale, so combination weights are also
the calibration between those two units.

## Adding a scorer

A scorer is a name, a state pointer, and a procedure with this shape:

```odin
Score_Proc :: #type proc(state: rawptr, data: []u8) -> f64
```

Add its state to `Scorer_Registry`, register its name in `lookup_scorer`, and the
CLI parser and weighted composition will handle it without changes to the scan
or decoder loops. Scorers run in the hot loop, so they should avoid allocation.
Expensive tokenizer, local-LM, executable, image, and music scorers will need a
cheap prefilter or staged scoring pipeline before being added.

Run the finite built-in checks with:

```sh
just test
```
