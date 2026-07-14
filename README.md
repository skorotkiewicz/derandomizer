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
language_score(candidate) - decoder_cost
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

The interesting next step is replacing `language_score` with a pluggable scorer:
compression gain, tokenizer likelihood, a tiny local LM, executable-program
behavior, image structure, music structure, or combinations of them.
