# System: graph model, compiler and runtime

**Sources:** `Sources/Graph/`
**Tests:** `Tests/CompositionModelTests.swift` (`CompositionModelTests`),
`Tests/GraphRuntimeTests.swift` (`GraphRuntimeTests`), `Tests/GraphEditingTests.swift`
(`GraphEditingTests`), `Tests/MacroGraphTests.swift` (`MacroGraphTests`),
`Tests/QCColorPatchTests.swift` (`QCColorPatchTests`),
`Tests/QuartzComposerMilestoneTests.swift` (`QuartzComposerCatalogTests`,
`QuartzComposerNestedGraphTests`, `QuartzComposerPreferenceTests`, `QuartzComposerRuntimeTests`,
`SyphonVendorModificationTests`), `Tests/FeedbackTests.swift` (`FeedbackTests`)
**Decisions:** `DEC-0002` (document format), `DEC-0007` (feedback as the cycle boundary),
`DEC-0012` (catalog vs functional), `DEC-0008` (OSC set), `DEC-0006` (generated definitions)

## Purpose

Define the composition document as typed value records, validate and version it, edit it with
undo, and compile it into a schedule that the renderer can evaluate every frame. This layer
computes **control** values (numbers, booleans, strings, colours, events) and opaque image
handles. It does not rasterise anything; real pixel work is in `systems/renderer.md`.

## Key files

| File | Responsibility | ~Lines |
| --- | --- | --- |
| `CompositionModel.swift` | IDs, `PortDataType`/`PortDirection`, `JSONValue`, `ParameterValue`, node/port/connection/child-graph/`GraphRecord`/`CompositionFile`, `CompositionCodec`, `GraphValidator` | 599 |
| `GraphRuntime.swift` | `GraphCompiler`, `GraphSnapshot`/`GraphSchedule`, `GraphRuntime` evaluator, `ControlPatchExecutor`, `QCControlMath` | 1131 |
| `PatchDescriptor.swift` | `PatchExecutorKind`, `PatchDefinition`, `ParameterSchema`, `PatchRegistry.builtIns`, container/consumer flags, custom-shader metadata | 1217 |
| `MacroGraph.swift` | Macro records, graph accessors, `MacroValidator`, `MacroExpander`, `MacroConverter` | 723 |
| `LegacyPatchCatalog.swift` | `PatchCatalogStatus`, the reconstructed Quartz Composer library and section tree, `isAddable` | 740 |
| `GraphEditing.swift` | `GraphCommand` with inverses, `GraphClipboardPayload`, `GraphRecord.reidentified(offset:)` | 184 |
| `QCColorMath.swift` | Framework-probe-measured RGB/HSL conversion, `transform`, `mix` | 194 |
| `QuartzComposerColorPatches.swift` | **Generated** six `Utility > Color` patch definitions — do not hand-edit | 166 |

## Compile and evaluate flow

`GraphCompiler.compile(graph, macros:)`:

1. `GraphValidator.validate(graph)` — throw `GraphCompilationError.invalidGraph` if not empty.
2. `MacroExpander.expand` — inline macro instances, recursively expand child graphs. Failure
   throws `.invalidMacros`.
3. Validate the expanded graph again.
4. `GraphSnapshot` marks every node whose `patchType` has no `PatchRegistry.definition` as
   `isDisabled` (data is preserved, evaluation skips it with a warning).
5. Kahn topological sort (see invariants), producing `GraphSchedule { snapshot, nodes }`.

`GraphRuntime` is a `final class` holding a cached `[ExecutionNodeKey: PatchExecutor]` map so
stateful executors (`.smooth`) survive between frames. `evaluate(context:)` returns
`GraphEvaluation { values, scopedValues, consumers, diagnostics }`; consumers are sorted by
`layer`, then by `EvaluationPath` lexicographically.

There is exactly one executor implementation, `ControlPatchExecutor`, created by
`PatchExecutorFactory.make`. All 52 `PatchExecutorKind` cases share it. Image kinds returned by
it are placeholders — pass-through of the `image` input, an empty dictionary, or a throw:

- `.unavailableImage`, `.movieImage`, `.cameraImage`, `.syphonInput` throw
  `PatchExecutionError.unavailable("Image loading is not active until the image-pipeline
  milestone.")`.
- `.linearGradient` returns a pixel-less placeholder `ImageRuntimeValue`.
- `.feedback` returns its input; the previous frame comes from the renderer's store.
- Container and consumer kinds return `[:]` and are handled by the renderer.

## Containers, macros and consumers

- `isContainer` = `iterator`, `transformation3D`, `replicateInSpace`, `lighting`. Each is
  evaluated by `evaluateContainer`, which recompiles the child graph on every evaluation and
  pushes an `IteratorRuntimeFrame` / `TransformRuntimeFrame` / `LightingRuntimeFrame` into the
  `RuntimeEvaluationScope`. Value scoping is keyed by `EvaluationPath`.
- `iteratorVariables` is special-cased in `evaluate`; outside an iterator child graph it emits an
  error diagnostic.
- Macros are expanded at compile time, so a macro instance has no runtime cost of its own.
  `MacroValidator` rejects duplicate, malformed, missing, mis-typed, boundary-invalid and
  recursive definitions; `MacroConverter.convert` throws `.emptySelection` / `.invalidSelection`.
- `isConsumer` = `previewOutput`, `syphonOutput`, `clear`, `renderGradient`, `billboard`,
  `qcSprite`, `cube`, `sphere`, `particleSystem`. An enabled consumer produces a
  `ConsumerExecution` carrying layer, path, scope (blending/depth-testing/face-culling) and its
  inputs.

## Concurrency

- Nothing in `Sources/Graph/` is an `actor`, `@MainActor`, lock, queue or `@unchecked Sendable`.
- `GraphRuntime` is a plain non-`Sendable` class. It is safe only because `MetalImageRenderer`
  (which is `@MainActor`) owns and drives it. Do not move evaluation off the main actor without
  making this type an actor or adding synchronization.
- Records, `FrameContext`, `RuntimeValue`, `GraphSchedule`, `GraphEvaluation` and
  `PatchDefinition` are `Sendable` value types; keep it that way so frames cross isolation domains
  as values.

## Exact constants

| Constant | Value | Symbol |
| --- | --- | --- |
| Format identifier | `com.steolepanda.metaliquartz.composition` | `CompositionFile.formatIdentifier` |
| Current document version | 2 (accepts 0 via migration, and 1) | `CompositionFile.currentVersion` |
| Iterator/replicate evaluation budget | 4 096 executions per frame | local `evaluationBudget` in `GraphRuntime.evaluate` |
| Iterator `count` / replicate `copies` range | default 1, `0...4_096` | `ParameterSchema` |
| Smoothing response | `max(0.001, response)` s, schema `0.001...5` | `ControlPatchExecutor` `.smooth` |
| Interpolation duration floor | `max(0.001, duration)`; schema `0.001...3_600` | `QCControlMath.interpolation` |
| LFO period floor / PWM clamp | `max(0.001, period)` / `0...1` | `QCControlMath.lfo` |
| `qcMath` operation cap / spline control points | `prefix(64)` / `prefix(16)`, tension `-1...1` | `QCControlMath` |
| Custom shader parameter cap | 4 | `CustomShaderSource.parameterDeclarations` |
| Lighting | 8 lights max; `shininess` 32 (0...128), `specularity` 0.5 (0...1), `lightCount` 1 (0...8) | `PatchDescriptor.swift` |
| Geometry grid | `columns` 64, `rows` 36, both clamped `2...256` | `PatchDescriptor.swift` |
| Clipboard duplicate offset | `(32, 32)` | `GraphClipboardPayload` |
| Default live session | resolution `"1920×1080"`, OSC port 9 000 | `LiveSessionSettings.default` |

Do not restate these in another page; link here or to the symbol.

## Invariants and rejection rules

Feedback is the only legal frame cycle (`DEC-0007`). `NodeRecord.breaksFrameCycle` is hard-coded
to `patchType == "com.steolepanda.metaliquartz.feedback"`, and both the validator and the
compiler drop outgoing edges from such a node when detecting cycles.

`GraphValidator.validate` reports `GraphValidationIssue`: `duplicateNode`, `duplicatePort`,
`duplicateConnection`, `missingNode`, `missingPort`, `invalidOutputPort`, `invalidInputPort`,
`typeMismatch(output:input:)`, `inputAlreadyConnected` (one connection per input port),
`cycleDetected`, `duplicateChildGraph`, `orphanChildGraph`, `invalidChildGraphOwner`,
`invalidChildGraph(owner:issues:)`.

`GraphCommand.addConnection` **replaces** any existing connection on the same input port (tested).
`GraphCommand.addNodes` filters duplicate IDs and creates an empty child graph for a container
patch. `removeNodes` cascades to child graphs and attached connections, and is undoable.

`CompositionCodec` uses ISO-8601 dates and pretty-printed, sorted-key JSON without escaped
slashes. Decoding rejects a wrong format (`invalidFormat`) and an unsupported version
(`unsupportedVersion`); the version-0 branch skips the format check because it predates it.

## Known limits and dead code

- The `.linearGradient` runtime result carries no pixels; the gradient is produced by the
  renderer when it executes the same node kind. This is intentional duplication of *shape*, not
  of *work*: the runtime value only carries identity.
- The 4 096 budget throttles iterator/replicate iteration only. There is no cap on node, port or
  connection count, no macro nesting-depth cap and no evaluation recursion-depth cap.
- `PatchRegistry.definition(for:)` is an O(n) scan over the built-in list.
- The catalog is a reconstructed superset, not a complete QC runtime. Two OpenCL rows are marked
  deprecated; unmapped rows are `catalogOnly` and cannot be added (`DEC-0012`).
- No test covers the evaluation budget or nesting depth (finding D14 in `CURRENT_STATE.md`).

## Tests that protect this

| Behaviour | Test |
| --- | --- |
| Codec round-trip, v0 migration, version rejection | `CompositionModelTests` |
| Validator rules, feedback boundary | `CompositionModelTests` |
| Topological order, determinism, smooth state | `GraphRuntimeTests` |
| Undo, connection replacement, clipboard identity | `GraphEditingTests` |
| Macro conversion, nesting, recursion, ownership | `MacroGraphTests` |
| Catalog rows, catalog-only rules, deprecated surface | `QuartzComposerCatalogTests` |
| v1 migration, child ownership, clipboard child identity | `QuartzComposerNestedGraphTests` |
| Category colours, rotary fader arc | `QuartzComposerPreferenceTests` |
| LFO/interp/math, iterator scoping, layer sort | `QuartzComposerRuntimeTests` |
| Vendored Syphon modification present | `SyphonVendorModificationTests` |
| Framework-probe colour arithmetic, generated definitions | `QCColorPatchTests` |
| Feedback one-frame delay and texture reuse | `FeedbackTests` |

Generated definitions are additionally guarded by
`Scripts/generate-swift-color-patches.py --check`, which `Scripts/verify.sh` runs.

The generator consumes the public hash-guarded six-patch schema under
`docs/verification/fixtures/qc-color-generation-schema.json`; local framework captures are not
needed for this check. The generated Swift bytes and port behavior are unchanged.
