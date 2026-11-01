using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using Maaso.World;
using UnityEngine;

namespace Maaso.Avatar
{
    [Serializable]
    public sealed class AvatarPresenceCommand
    {
        public string requestId;
        public string transitionId;
        public string phase;
        public string edge;
        public int durationMs;
        public bool stationaryWalk;
        public bool doNotInterrupt;
        public long sequence;
        public long expiresAtMs;
    }

    [Serializable]
    public sealed class AvatarPresenceResult
    {
        public string method = "transitionPresence";
        public string requestId;
        public string transitionId;
        public string phase;
        public bool ok;
        public string code;
    }

    // A single local rendering transaction. It owns pose, visibility and camera
    // until entry/restore; account ownership and transport are owned by Flutter.
    public sealed class AvatarPresenceTransitionController
    {
        private readonly Action<AvatarPresenceResult> report;
        private readonly Dictionary<string, long> sequences = new();
        private readonly Dictionary<string, AvatarPresenceResult> receipts = new();
        private readonly HashSet<string> retired = new();
        private Transform root;
        private FrontFullBodyCamera framing;
        private Camera camera;
        private Animator animator;
        private Renderer[] renderers;
        private bool[] originalHidden;
        private bool originalRootMotion;
        private bool framingEnabled;
        private string framingMode;
        private Vector3 homePosition, homeScale, cameraPosition;
        private float cameraFieldOfView;
        private Quaternion homeRotation, cameraRotation;
        private Vector3 startPosition, endPosition;
        private Quaternion walkRotation;
        private string transitionId;
        private AvatarPresenceCommand pending;
        private float startedAt;
        private Action stopWalk;
        private bool walkingRunning;
        private bool idleRequested;
        private float observedAt;
        private Animator walkingSpeedResetAnimator;
        private float walkingSpeedResetAt;
        private const float WalkingIdleBlendSeconds = .2f;
        private bool hidden;
        private bool presentationHeld;
        private bool yieldsToScene;
        private string resetPrepareId;

        public AvatarPresenceTransitionController(Action<AvatarPresenceResult> report) => this.report = report;
        public bool OwnsPresentation => presentationHeld && root != null && transitionId != null;
        public bool IsHidden => OwnsPresentation && hidden;
        public bool IsMoving => pending != null;

        // A foreground entrance is cosmetic. Explicit scene composition can
        // retire it atomically before taking the pose/camera. Device handoffs
        // retain their stronger ownership and are never released here.
        public bool ReleaseForScene(string requestedFraming = null)
        {
            if (!OwnsPresentation || !yieldsToScene) return false;
            if (requestedFraming != null && NormalizeFraming(requestedFraming) == NormalizeFraming(framingMode))
                return false;
            CancelForReset("scene_takeover");
            return true;
        }

        private static string NormalizeFraming(string value)
        {
            string mode = (value ?? string.Empty).Trim().ToLowerInvariant().Replace('-', '_').Replace(' ', '_');
            return mode == string.Empty || mode == "full_body" ? "hero_full_body" : mode;
        }

        public void Execute(AvatarPresenceCommand command, Transform avatar,
            FrontFullBodyCamera view, Func<bool> startWalk, Action finishWalk,
            float now, long utcNowMs)
        {
            if (!Valid(command, utcNowMs)) { Reply(command, false, "invalid_or_expired_request"); return; }
            if (receipts.TryGetValue(command.requestId, out AvatarPresenceResult previous))
            {
                if (previous.transitionId == command.transitionId && previous.phase == command.phase) report(previous);
                else Reply(command, false, "duplicate_request");
                return;
            }
            if (pending?.requestId == command.requestId) return;
            if (command.phase == "prepare" && resetPrepareId == command.transitionId &&
                (!sequences.TryGetValue(command.transitionId, out long priorSequence) || command.sequence > priorSequence))
            {
                retired.Remove(command.transitionId);
                resetPrepareId = null;
            }
            if (retired.Contains(command.transitionId) ||
                (sequences.TryGetValue(command.transitionId, out long sequence) && command.sequence <= sequence))
            { Reply(command, false, "stale_request"); return; }
            sequences[command.transitionId] = command.sequence;
            bool same = transitionId == command.transitionId;
            // A Home preview can leave after remote ownership is confirmed.
            // It may start a fresh exit only while presentation is unclaimed;
            // the following busy gate still protects an active device handoff.
            if (!same && command.doNotInterrupt && command.phase != "prepare" && command.phase != "exit")
            { Reply(command, false, "transition_mismatch"); return; }
            if (!same && OwnsPresentation && command.doNotInterrupt)
            { Reply(command, false, "transition_busy"); return; }
            if (same && !presentationHeld && command.phase != "holdHidden" && command.phase != "restore")
            { Reply(command, false, "transition_completed"); return; }
            if (!same && (command.phase == "restore" || command.phase == "enter"))
            { Reply(command, false, "transition_mismatch"); return; }
            if (!same && OwnsPresentation && command.phase != "prepare" && command.phase != "holdHidden")
            { Reply(command, false, "transition_busy"); return; }
            if (avatar == null || view == null || view.GetComponent<Camera>() == null)
            { Reply(command, false, "renderer_unavailable"); return; }
            observedAt = now;

            if (!same)
            {
                CancelForReset("superseded");
                Capture(avatar, view, command.transitionId, finishWalk, command.doNotInterrupt);
            }
            presentationHeld = true;
            framing.enabled = false;
            camera.transform.SetPositionAndRotation(cameraPosition, cameraRotation);
            camera.fieldOfView = cameraFieldOfView;
            bool refreshHiddenEntry = command.phase == "enter" && hidden && pending == null;
            CancelPending("cancelled");
            if (command.phase == "restore")
            {
                // A desktop arrival may need another hidden-frame recovery if
                // native capture/reveal fails after this acknowledgement. Keep
                // its identity fenced until a newer handoff supersedes it;
                // holdHidden must reacquire presentation before preparing again.
                Restore(!command.stationaryWalk);
                Reply(command, true, "");
                return;
            }
            if (command.phase == "prepare" || command.phase == "holdHidden")
            {
                SetHidden(true);
                FinishWalking(deferSpeedReset: false);
                if (command.phase == "prepare" && !command.stationaryWalk)
                {
                    SetHomePose();
                    RefreshHiddenHomeProjection();
                }
                Reply(command, true, "");
                return;
            }
            try
            {
                SetHomePose();
                if (refreshHiddenEntry && !command.stationaryWalk) RefreshHiddenHomeProjection();
                Vector3 direction = Vector3.ProjectOnPlane(camera.transform.right, Vector3.up).normalized;
                if (direction.sqrMagnitude < 0.5f) throw new InvalidOperationException("camera_orientation");
                if (command.edge == "left") direction = -direction;
                Vector3 offset = command.stationaryWalk ? Vector3.zero : CalculateExitOffset(camera, AvatarBounds(), direction, command.edge == "left");
                bool entering = command.phase == "enter";
                startPosition = root.position + (entering ? offset : Vector3.zero);
                endPosition = root.position + (entering ? Vector3.zero : offset);
                Vector3 travel = entering ? -direction : direction;
                walkRotation = Quaternion.LookRotation(travel, Vector3.up) * AuthoredForwardCorrection(root);
                root.position = startPosition;
                if (entering) root.rotation = walkRotation;
                if (animator != null) animator.applyRootMotion = false;
                CancelWalkingSpeedReset();
                idleRequested = false;
                if (startWalk == null || !startWalk()) throw new InvalidOperationException("walk_unavailable");
                walkingRunning = true;
                if (!command.stationaryWalk)
                {
                    float movingSeconds = command.durationMs / 1000f * (entering ? .85f : .8f);
                    WorldLocomotionPresentation.ApplyWalkingAnimationSpeed(animator, true,
                        Vector3.Distance(startPosition, endPosition) / movingSeconds);
                }
                SetHidden(false);
                startedAt = now;
                pending = command;
            }
            catch (Exception exception)
            {
                Restore(true);
                Reply(command, false, exception.Message);
            }
        }

        public void Advance(float now, long utcNowMs)
        {
            observedAt = now;
            AdvanceWalkingSpeedReset(now);
            if (transitionId != null && (root == null || camera == null || framing == null))
            {
                CancelForReset("renderer_destroyed");
                return;
            }
            if (!OwnsPresentation) return;
            // Other camera directors cannot pull the avatar back into frame.
            framing.enabled = false;
            camera.transform.SetPositionAndRotation(cameraPosition, cameraRotation);
            camera.fieldOfView = cameraFieldOfView;
            if (hidden) SetHidden(true);
            if (pending == null) return;
            if (utcNowMs > pending.expiresAtMs)
            {
                CancelPending("expired");
                SetHidden(true);
                return;
            }
            float elapsed = Mathf.Max(0f, now - startedAt);
            float duration = pending.durationMs / 1000f;
            float t = elapsed + .00001f >= duration ? 1f : Mathf.Clamp01(elapsed / duration);
            bool entering = pending.phase == "enter";
            // Leave time to turn before departing, and face home again on entry.
            float turnSeconds = pending.stationaryWalk ? 0.2f : duration * 0.2f;
            float move = entering ? Mathf.Clamp01(t / 0.85f) :
                Mathf.Clamp01((elapsed - turnSeconds) / (duration - turnSeconds));
            // realtimeSinceStartup is a float. Subtracting a later start time
            // must not defer this boundary by a whole rendered frame.
            if (entering && elapsed + .00001f >= duration * .85f) move = 1f;
            // Keep the moving segment at the same constant speed as the
            // calibrated gait. Easing only the root compresses early/late steps.
            root.position = Vector3.Lerp(startPosition, endPosition, move);
            Quaternion homeWorldRotation = root.parent != null ? root.parent.rotation * homeRotation : homeRotation;
            float facingHome = Mathf.Clamp01((t - 0.85f) / 0.15f);
            root.rotation = entering
                ? Quaternion.Slerp(walkRotation, homeWorldRotation, Mathf.SmoothStep(0f, 1f, facingHome))
                : Quaternion.Slerp(homeWorldRotation, walkRotation, Mathf.Clamp01(elapsed / turnSeconds));
            // The final turn is a standing arrival. Blend out the walk when
            // translation finishes, instead of swinging the feet in place and
            // only stopping them after the actor faces the camera. A stationary
            // desktop walk still belongs to the native window's moving route.
            if (entering && !pending.stationaryWalk && move >= 1f) FinishWalking();
            if (t < 1f) return;
            AvatarPresenceCommand completed = pending;
            pending = null;
            if (entering) Restore(false, keepDeliveredHomeProjection: true);
            else
            {
                SetHidden(true);
                FinishWalking(deferSpeedReset: false);
            }
            Reply(completed, true, "");
        }

        public void CancelForReset(string reason)
        {
            CancelPending(reason);
            if (transitionId == null) { FinishWalking(deferSpeedReset: false); return; }
            resetPrepareId = reason == "model_replaced" || reason == "renderer_disabled" || reason == "renderer_destroyed"
                ? transitionId : null;
            if (presentationHeld) Restore(true);
            else
            {
                retired.Add(transitionId);
                transitionId = null;
                root = null;
            }
            // The next model, scene or movement owns its own gait. Retired
            // presentation cleanup may never write its speed in a later frame.
            FinishWalking(deferSpeedReset: false);
        }

        private void CancelPending(string reason)
        {
            if (pending == null) return;
            AvatarPresenceCommand cancelled = pending;
            pending = null;
            FinishWalking();
            Reply(cancelled, false, reason);
        }

        private void Capture(Transform avatar, FrontFullBodyCamera view, string id, Action finishWalk, bool canYield)
        {
            resetPrepareId = null;
            root = avatar;
            framing = view;
            camera = view.GetComponent<Camera>();
            transitionId = id;
            presentationHeld = true;
            yieldsToScene = canYield;
            stopWalk = finishWalk;
            walkingRunning = false;
            idleRequested = false;
            homePosition = root.localPosition;
            homeRotation = root.localRotation;
            homeScale = root.localScale;
            cameraPosition = camera.transform.position;
            cameraRotation = camera.transform.rotation;
            cameraFieldOfView = camera.fieldOfView;
            framingEnabled = framing.enabled;
            framingMode = framing.FramingMode;
            framing.ReleasePresenceCameraRoute();
            framing.enabled = false;
            // Disabling Home framing releases its indoor lens adjustment.
            // Presence holds the rendered projection, including that lens.
            camera.fieldOfView = cameraFieldOfView;
            renderers = root.GetComponentsInChildren<Renderer>(true);
            originalHidden = new bool[renderers.Length];
            for (int i = 0; i < renderers.Length; i++) originalHidden[i] = renderers[i].forceRenderingOff;
            animator = root.GetComponentInChildren<Animator>(true);
            if (animator != null)
            {
                originalRootMotion = animator.applyRootMotion;
                animator.applyRootMotion = false;
            }
        }

        private void Restore(bool retire, bool keepDeliveredHomeProjection = false)
        {
            FinishWalking();
            SetHomePose();
            SetHidden(false);
            if (animator != null) animator.applyRootMotion = originalRootMotion;
            if (camera != null)
            {
                camera.transform.SetPositionAndRotation(cameraPosition, cameraRotation);
                camera.fieldOfView = cameraFieldOfView;
            }
            if (framing != null)
            {
                framing.SetFramingMode(framingMode);
                if (keepDeliveredHomeProjection && framingEnabled)
                    framing.CompletePresenceCameraRoute(root);
                framing.enabled = framingEnabled;
            }
            // OnEnable frames the final Home projection atomically. Do not
            // overwrite its new position with a pose captured before a resize.
            presentationHeld = false;
            if (retire)
            {
                if (transitionId != null) retired.Add(transitionId);
                transitionId = null;
                root = null;
            }
            pending = null;
        }

        private void FinishWalking(bool deferSpeedReset = true)
        {
            if (idleRequested)
            {
                if (!deferSpeedReset)
                {
                    CancelWalkingSpeedReset();
                    WorldLocomotionPresentation.ApplyWalkingAnimationSpeed(animator, false);
                }
                return;
            }
            bool wasWalking = walkingRunning;
            walkingRunning = false;
            idleRequested = true;
            stopWalk?.Invoke();
            if (wasWalking && deferSpeedReset && animator != null)
            {
                // The outgoing walk still contributes to the .2-second idle
                // blend. Changing its playback rate now creates a visible jerk.
                walkingSpeedResetAnimator = animator;
                walkingSpeedResetAt = observedAt + WalkingIdleBlendSeconds;
            }
            else
            {
                CancelWalkingSpeedReset();
                WorldLocomotionPresentation.ApplyWalkingAnimationSpeed(animator, false);
            }
        }

        private void AdvanceWalkingSpeedReset(float now)
        {
            if (walkingSpeedResetAnimator == null || now < walkingSpeedResetAt) return;
            Animator target = walkingSpeedResetAnimator;
            CancelWalkingSpeedReset();
            // A short entrance can release presentation before its blend ends.
            // A newer world walk can start then without taking Presence again.
            if (WorldLocomotionPresentation.TryGetWalkingPhase(target, out _)) return;
            WorldLocomotionPresentation.ApplyWalkingAnimationSpeed(target, false);
        }

        private void CancelWalkingSpeedReset() => walkingSpeedResetAnimator = null;

        private void RefreshHiddenHomeProjection()
        {
            if (!hidden || !framing.FrameHiddenHomePresentation(root)) return;
            cameraPosition = camera.transform.position;
            cameraRotation = camera.transform.rotation;
            cameraFieldOfView = camera.fieldOfView;
        }

        private void SetHomePose()
        {
            if (root == null) return;
            root.localPosition = homePosition;
            root.localRotation = homeRotation;
            root.localScale = homeScale;
        }

        private void SetHidden(bool value)
        {
            hidden = value;
            if (renderers == null) return;
            for (int i = 0; i < renderers.Length; i++)
                if (renderers[i] != null) renderers[i].forceRenderingOff = value || originalHidden[i];
        }

        private Bounds AvatarBounds()
        {
            Bounds bounds = new(root.position, Vector3.zero);
            bool found = false;
            foreach (Renderer renderer in renderers)
            {
                // Ownership can disable the local renderer while the target
                // prepares offscreen. Geometry still exists and is required
                // to place the entire model outside the viewport.
                if (renderer == null) continue;
                if (!found) { bounds = renderer.bounds; found = true; }
                else bounds.Encapsulate(renderer.bounds);
            }
            if (!found || bounds.size.sqrMagnitude < 0.01f) throw new InvalidOperationException("avatar_bounds_unavailable");
            // A conservative horizontal radius covers arms and the complete turn.
            Vector3 centerOffset = bounds.center - root.position;
            float radius = new Vector2(bounds.extents.x + Mathf.Abs(centerOffset.x),
                bounds.extents.z + Mathf.Abs(centerOffset.z)).magnitude;
            bounds.center = new Vector3(root.position.x, bounds.center.y, root.position.z);
            bounds.extents = new Vector3(radius, bounds.extents.y + 0.05f, radius);
            return bounds;
        }

        public static Vector3 CalculateExitOffset(Camera camera, Bounds bounds, Vector3 direction, bool left)
        {
            if (camera == null || direction.sqrMagnitude < 0.5f) throw new ArgumentException("camera_geometry");
            direction.Normalize();
            // A side-plane test remains valid when a close portrait's full-body
            // bounds intersect the near plane; dividing corners by z does not.
            Ray edgeRay = camera.ViewportPointToRay(new Vector3(left ? -0.08f : 1.08f, 0.5f, 0f));
            Vector3 inward = camera.orthographic ? camera.transform.right :
                Vector3.Cross(camera.transform.up, edgeRay.direction).normalized;
            if (!left) inward = -inward;
            Plane edgePlane = new(inward, edgeRay.origin);
            bool Outside(float distance)
            {
                for (int i = 0; i < 8; i++)
                {
                    Vector3 corner = bounds.center + Vector3.Scale(bounds.extents,
                        new Vector3((i & 1) == 0 ? -1 : 1, (i & 2) == 0 ? -1 : 1, (i & 4) == 0 ? -1 : 1));
                    if (edgePlane.GetDistanceToPoint(corner + direction * distance) > -0.025f) return false;
                }
                return true;
            }
            float high = 1f;
            while (high < 128f && !Outside(high)) high *= 2f;
            if (!Outside(high)) throw new InvalidOperationException("exit_geometry_unavailable");
            float low = 0f;
            for (int i = 0; i < 24; i++)
            {
                float mid = (low + high) * 0.5f;
                if (Outside(mid)) high = mid; else low = mid;
            }
            return direction * high;
        }

        private static Quaternion AuthoredForwardCorrection(Transform avatar)
        {
            Animator human = avatar.GetComponentInChildren<Animator>(true);
            if (human == null || !human.isHuman) return Quaternion.identity;
            Transform left = human.GetBoneTransform(HumanBodyBones.LeftUpperArm);
            Transform right = human.GetBoneTransform(HumanBodyBones.RightUpperArm);
            Transform hips = human.GetBoneTransform(HumanBodyBones.Hips);
            Transform head = human.GetBoneTransform(HumanBodyBones.Head);
            if (left == null || right == null || hips == null || head == null) return Quaternion.identity;
            return Maaso.World.WorldAvatarFacing.ResolveCorrection(
                avatar.InverseTransformPoint(left.position), avatar.InverseTransformPoint(right.position),
                avatar.InverseTransformPoint(hips.position), avatar.InverseTransformPoint(head.position));
        }

        private static bool Valid(AvatarPresenceCommand command, long now)
        {
            if (command == null) return false;
            bool desktopExit = command.stationaryWalk && command.phase == "exit";
            int maximumDuration = desktopExit ? 60000 : 3000;
            long maximumLifetime = desktopExit ? Math.Max(15000, command.durationMs + 5000) : 15000;
            if (command.durationMs < 300 || command.durationMs > maximumDuration ||
                command.sequence <= 0 || command.expiresAtMs <= now || command.expiresAtMs > now + maximumLifetime ||
                (command.edge != "left" && command.edge != "right")) return false;
            bool Id(string value) => value != null && Regex.IsMatch(value, "^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$");
            return Id(command.requestId) && Id(command.transitionId) &&
                (command.phase == "prepare" || command.phase == "exit" || command.phase == "enter" ||
                 command.phase == "restore" || command.phase == "holdHidden");
        }

        private void Reply(AvatarPresenceCommand command, bool ok, string code)
        {
            AvatarPresenceResult result = new()
            {
                requestId = command?.requestId ?? "", transitionId = command?.transitionId ?? "",
                phase = command?.phase ?? "", ok = ok, code = code,
            };
            if (!string.IsNullOrEmpty(result.requestId)) receipts[result.requestId] = result;
            report(result);
        }
    }
}
