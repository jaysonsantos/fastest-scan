# 0008: Machine learning only at phone speed

Date: 2026-10-09. Status: accepted. The owner of the repository set this rule.

## Context

A neural network can find a page on a cluttered desk more reliably than line
detection (`docs/research/page-detection.md`). The library must also run in an
Android app.

## Decision

- The first version uses no machine learning.
- A model can enter later only when a phone runs it fast: a small model, on the
  device, at the frame rate that its step needs.
- A model sits behind the same interface as the classical step that it replaces
  (for example the page detector). The classical step stays as the fallback.

## Consequences

- Before a model is proposed, measure its size and its latency on mobile hardware.
- Large document models (transformers for dewarping, diffusion models) are not
  candidates.
