# Onyx

A native Mac assistant for voice and text commands, local app control, and agent task execution.

This repository opens up one piece of the system: **the run journal that makes interrupted agent work recoverable**.

[Journal implementation](RunJournal.swift) · [Tests](RunJournalTests.swift) · [Portfolio](https://advaitagupta.com)

## The engineering problem

An agent can crash after taking an action but before recording the result. Repeating the action blindly can make things worse.

Onyx records intent before execution. If a process stops with an unfinished intent, recovery marks that step as **unknown**, so the caller can check what happened before deciding how to proceed.

```text
Intent recorded
  -> action runs -> outcome recorded
  -> interruption -> unknown -> review
```

## Technical decisions

- **Durable state:** intent, done, failed, cancelled, and unknown outcomes.
- **Bounded storage:** at most 50 entries and a 24-hour read window.
- **Local encryption:** AES-GCM, atomic file replacement, and a separate mode-0600 key file.
- **Explicit recovery:** bounded labels and a stored precondition to check before resuming.

In the broader app, speech/text input flows through local command routing or typed model routing, then action classification and execution. The journal sits at that execution boundary. This repository contains the journal component and its synthetic tests, rather than an app installer.

## Run the tests

Requires macOS and Xcode Command Line Tools (`swiftc`). Uses Apple's Foundation and CryptoKit frameworks; no external packages or API keys.

```sh
git clone https://github.com/Advaita-G/onyx-engineering.git
cd onyx-engineering
swiftc -warnings-as-errors RunJournal.swift RunJournalTests.swift -o /tmp/onyx-journal-tests
/tmp/onyx-journal-tests
```

Expected: `RunJournalTests: PASS (...)`. Keep assertions enabled. The tests use a temporary directory and clean it up afterward.

Coverage includes encryption round trips, interrupted-step recovery, repeat recovery, precondition mismatch, expiry, entry bounds, corrupt-file errors, erasure, and key permissions. The documented command passed in this repository and in a fresh public clone during the 2026-10-20 review.

## Component limits

The journal records outcomes; it does not execute actions or guarantee exactly-once execution. The caller must persist intent before the side effect and resolve unknown outcomes.

The encryption key is stored beside the ciphertext, so a process with access to both can decrypt it. The lock coordinates threads within one process. Multi-process locking, symlink hardening, missing/corrupt key recovery, and crash fault injection need further work before sensitive reuse. Expiry filters reads rather than guaranteeing physical deletion; erasing the journal leaves the key file.

<details>
<summary>Full app status and privacy</summary>

The full assistant remains a development project. Its release review identified personal material in tracked evidence, privacy defaults inconsistent with older documentation, and best-effort shell restrictions rather than a sandbox. Only the reviewed journal source and synthetic fixtures are distributed here; the app, vault, conversation history, credentials, and private research are excluded.

</details>

## Attribution

Built by Advaita Gupta with Codex and Claude assistance. These component files were added together in implementation commit `010778a`, after the project's initial workspace import. Foundation and CryptoKit are Apple frameworks. Full-app provenance and redistribution review remain separate from this component showcase.
