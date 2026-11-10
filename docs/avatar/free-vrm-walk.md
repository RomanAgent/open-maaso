# Bundled free-VRM walking

The local character controller contains `Idle` and `standard_walk`. Both Home
presence entry and Agent Space already request that exact walk state through
`UnityAvatarCommandReceiver`; an Idle-only controller made entry return
`walk_unavailable` and left room travel visibly sliding without a gait.

`OpenMaasoWalkClipBuilder` creates a project-authored Humanoid cycle from the
verified model-specific idle baseline. Its Editor-only two-bone authoring
plants alternate feet, lifts the opposite foot and counter-swings the arms,
then bakes the resulting muscle curves. Fingers retain their imported pose;
eye and jaw curves remain absent so gaze and TTS keep their ownership.
No motion capture or paid animation asset is copied.

The authored cycle is 0.8 seconds at 1.6 metres/second. Humanoid trajectory
metadata allows the existing `WorldLocomotionPresentation` to calibrate the
actual navigation rate. The native receiver keeps `applyRootMotion=false`:
room/presence transactions remain the sole owners of world translation.
Tests verify the actor transform remains fixed, its pelvis does not drift
within that root or accumulate over repeated cycles, and the body closes at
the loop seam. `WorldWalkStride` blends against a same-duration neutral pose,
so shorter step amplitudes retain the existing gait clock.

Focused tests use the actual bundled VRM, Animator and receiver to check the
required state, complete body curves, alternating feet/knee motion, measured
speed calibration, held-target continuity and the return to the corrected idle.
Editor-only GPU/AgentSpace probes retain separate local evidence; they are not
phone recordings or a substitute for signed-device acceptance.

The focused EditMode gate passes six walk checks plus both existing idle-pose
checks. A real Editor PlayerLoop/GPU probe additionally exercises the existing
Receiver commands: enter Agent Space, move 2.2 metres, complete to Idle, start a
second move and cancel back Home. Its support-foot samples exclude the native
turning phase; no new runtime animation driver or alternate position owner is
introduced. The Home presence probe also verifies cold entry, repeated restore
and cancellation with the same controller. Device acceptance remains a separate
signed iOS Release check.
