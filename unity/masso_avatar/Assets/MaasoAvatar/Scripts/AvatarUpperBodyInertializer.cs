using System;
using System.Collections.Generic;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>
    /// A bounded correction of ordinary upper-body Animator state changes.
    /// Restore in Update, then sample/apply after Animator and before gaze,
    /// contact IK and UniVRM's normalized-to-raw pass. This helper never evaluates
    /// an Animator or writes a root, hip, leg, head, neck, jaw or eye transform.
    /// </summary>
    public sealed class AvatarUpperBodyInertializer
    {
        public const float TransitionSeconds = .36f;
        public const float MaximumOffsetDegrees = 180f;
        // Estimate-only guard, matching the original source inertializer.
        // Authored frame rotations/velocities are never continuously clamped.
        public const float MaximumAngularSpeed = 25f;
        private const float SourceCorrectionTargetSpeed = 6f;
        private const float MaximumSourceTransitionSeconds = .55f;
        private const float OwnershipTolerance = .025f;
        private readonly List<BoneState> bones = new();
        private Animator animator;
        private UnityEngine.Avatar boundAvatar;
        private bool transitionRequested;
        private bool deferredTransition;
        private bool sourceTransitionRequested;
        private bool deferredSourceTransition;
        private bool presentedTransitionRequested;
        private bool sampled;
        private float lastSampleAt;
        private float transitionAt = float.NegativeInfinity;
        private float transitionDuration = TransitionSeconds;

        private sealed class BoneState
        {
            public Transform Transform;
            public Quaternion Source, Written, Output, PreviousSource, Presented;
            public bool PresentedValid;
            public Vector3 OutputVelocity, Offset, OffsetVelocity;
            public bool HasWrite;
        }

        public int BoneCount => bones.Count;
        public bool Transitioning { get; private set; }

        public void Bind(Animator target)
        {
            if (animator == target && target != null && target.avatar == boundAvatar && bones.Count > 0) return;
            Reset();
            animator = target;
            boundAvatar = target != null ? target.avatar : null;
            bones.Clear();
            if (target == null || !target.isHuman) return;
            // Animator.GetBoneTransform resolves the active normalized control
            // rig for runtime VRM, and the actual Humanoid rig for FBX (Matt).
            foreach (HumanBodyBones bone in SelectedBones)
            {
                Transform transform = target.GetBoneTransform(bone);
                if (transform != null) bones.Add(new BoneState { Transform = transform });
            }
        }

        /// <summary>Call once for a real state/layer change, not every frame.</summary>
        public void RequestTransition() => transitionRequested = sampled;

        /// <summary>
        /// A state selected in LateUpdate has not evaluated its transforms yet.
        /// Hold that request until the following Animator evaluation boundary.
        /// </summary>
        public void RequestTransitionAfterEvaluation() => deferredTransition = sampled;

        /// <summary>A different authored source has no measured incoming
        /// velocity yet. Never infer that velocity from the pose discontinuity
        /// between two unrelated clips.</summary>
        public void RequestSourceTransition()
        {
            transitionRequested = sampled;
            sourceTransitionRequested = sampled;
        }

        /// <summary>The native upper layer evaluates its newly selected source
        /// on the next Animator boundary, rather than in this LateUpdate.</summary>
        public void RequestSourceTransitionAfterEvaluation()
        {
            deferredTransition = sampled;
            deferredSourceTransition = sampled;
        }

        /// <summary>Seed only a routine overlay exit from what was actually
        /// presented. Never feed corrections back into the normal per-frame
        /// Animator source; task takeover still uses immediate Reset.</summary>
        public void RequestPresentedTransition()
        {
            transitionRequested = sampled;
            presentedTransitionRequested = sampled;
        }

        public void CapturePresentedPose()
        {
            foreach (BoneState bone in bones)
                if (bone.Transform != null)
                { bone.Presented = SafeRotation(bone.Transform.localRotation); bone.PresentedValid = true; }
        }

        /// <summary>Receiver Update entry, before Animator evaluates this frame.</summary>
        public void BeforeAnimatorEvaluation()
        {
            RestoreBeforeAnimation();
            if (!deferredTransition) return;
            transitionRequested = sampled;
            sourceTransitionRequested |= deferredSourceTransition && sampled;
            deferredTransition = false;
            deferredSourceTransition = false;
        }

        /// <summary>
        /// Return only values still owned by this correction before Animator
        /// evaluates a new frame. A later owner (IK/gaze/task) is never reverted.
        /// </summary>
        public void RestoreBeforeAnimation()
        {
            foreach (BoneState bone in bones)
            {
                if (!bone.HasWrite) continue;
                if (bone.Transform != null &&
                    Quaternion.Angle(bone.Transform.localRotation, bone.Written) < OwnershipTolerance)
                    bone.Transform.localRotation = bone.Source;
                bone.HasWrite = false;
            }
        }

        public void Apply(float now, bool allowed)
        {
            // Also makes manual edit-mode stepping safe when no Update occurred.
            RestoreBeforeAnimation();
            if (!allowed || animator == null || !animator.isActiveAndEnabled ||
                !Finite(now) || (sampled && (now < lastSampleAt || now - lastSampleAt > .25f)))
            {
                Reset();
                return;
            }
            float delta = sampled ? now - lastSampleAt : 0f;
            bool begin = transitionRequested && sampled;
            if (begin)
            {
                transitionAt = now;
                transitionDuration = TransitionSeconds;
            }
            float elapsed = now - transitionAt;
            Transitioning = elapsed >= 0f && elapsed < transitionDuration;
            foreach (BoneState bone in bones)
            {
                if (bone.Transform == null) continue;
                Quaternion source = SafeRotation(bone.Transform.localRotation);
                if (begin)
                {
                    if (presentedTransitionRequested && bone.PresentedValid)
                    {
                        bone.Output = bone.Presented;
                        bone.OutputVelocity = Vector3.zero;
                    }
                    bone.Offset = Vector3.ClampMagnitude(Log(bone.Output * Quaternion.Inverse(source)),
                        MaximumOffsetDegrees * Mathf.Deg2Rad);
                    if (sourceTransitionRequested)
                    {
                        // Quintic offset release peaks at 1.875 * angle/time.
                        // A large source handoff gets a little more time; the
                        // source itself still advances at its authored speed.
                        // The .55s ceiling bounds responsiveness, so this is a
                        // correction-speed target, never a universal limiter.
                        transitionDuration = Mathf.Max(transitionDuration, Mathf.Clamp(
                            1.875f * bone.Offset.magnitude / SourceCorrectionTargetSpeed,
                            TransitionSeconds, MaximumSourceTransitionSeconds));
                    }
                    // A CrossFade normally provides a continuous destination
                    // sample. Remove its estimated velocity, but do not treat
                    // a hard state discontinuity as actual physical velocity.
                    Vector3 incoming = !sourceTransitionRequested && sampled && delta > .001f &&
                        Quaternion.Angle(source, bone.PreviousSource) < 12f ?
                        Log(source * Quaternion.Inverse(bone.PreviousSource)) / delta : Vector3.zero;
                    bone.OffsetVelocity = Vector3.ClampMagnitude(bone.OutputVelocity - incoming, MaximumAngularSpeed);
                }
                Quaternion output = source;
                if (Transitioning)
                {
                    Vector3 offset = Decay(bone.Offset, bone.OffsetVelocity, elapsed, transitionDuration);
                    offset = Vector3.ClampMagnitude(offset, MaximumOffsetDegrees * Mathf.Deg2Rad);
                    output = SafeRotation(Exp(offset) * source);
                }
                // Only a real source switch adds a decaying offset. A genuine
                // stroke keeps its authored speed even during that transition;
                // when it ends the exact source is written with no catch-up.
                if (Transitioning || Quaternion.Angle(output, source) > .001f)
                {
                    bone.Source = source;
                    bone.Written = output;
                    bone.Transform.localRotation = output;
                    bone.HasWrite = true;
                }
                bone.OutputVelocity = sampled && delta > .001f ? Vector3.ClampMagnitude(
                    Log(output * Quaternion.Inverse(bone.Output)) / delta, MaximumAngularSpeed) : Vector3.zero;
                bone.Output = output;
                bone.PreviousSource = source;
            }
            transitionRequested = false;
            sourceTransitionRequested = false;
            presentedTransitionRequested = false;
            sampled = true;
            lastSampleAt = now;
        }

        /// <summary>Tasks, model replacement and disable release immediately.</summary>
        public void Reset()
        {
            RestoreBeforeAnimation();
            sampled = false;
            transitionRequested = false;
            deferredTransition = false;
            sourceTransitionRequested = false;
            deferredSourceTransition = false;
            presentedTransitionRequested = false;
            transitionAt = float.NegativeInfinity;
            transitionDuration = TransitionSeconds;
            Transitioning = false;
            foreach (BoneState bone in bones)
            {
                bone.OutputVelocity = Vector3.zero;
                bone.PresentedValid = false;
                bone.Offset = Vector3.zero;
                bone.OffsetVelocity = Vector3.zero;
            }
        }

        // Quintic rotation-vector offset with initial velocity and zero terminal
        // displacement/velocity/acceleration. Values are radians, never Euler.
        public static Vector3 Decay(Vector3 offset, Vector3 velocity, float elapsed, float duration)
        {
            if (!Finite(offset) || !Finite(velocity) || !Finite(elapsed) || !Finite(duration) || duration <= 0f)
                return Vector3.zero;
            if (elapsed <= 0f) return offset;
            if (elapsed >= duration) return Vector3.zero;
            float t = elapsed / duration, t2 = t * t, t3 = t2 * t, t4 = t3 * t, t5 = t4 * t;
            return offset * (1f - 10f * t3 + 15f * t4 - 6f * t5) +
                velocity * duration * (t - 6f * t3 + 8f * t4 - 3f * t5);
        }

        private static Quaternion Exp(Vector3 value)
        {
            float angle = value.magnitude;
            return angle < .000001f ? Quaternion.identity : Quaternion.AngleAxis(angle * Mathf.Rad2Deg, value / angle);
        }

        private static Vector3 Log(Quaternion value)
        {
            value = SafeRotation(value);
            if (value.w < 0f) value = new Quaternion(-value.x, -value.y, -value.z, -value.w);
            value.ToAngleAxis(out float angle, out Vector3 axis);
            return Finite(axis) && angle > .000001f ? axis * (angle * Mathf.Deg2Rad) : Vector3.zero;
        }

        private static Quaternion SafeRotation(Quaternion value)
        {
            float norm = value.x * value.x + value.y * value.y + value.z * value.z + value.w * value.w;
            if (!Finite(norm) || norm < .000001f) return Quaternion.identity;
            float scale = 1f / Mathf.Sqrt(norm);
            return new Quaternion(value.x * scale, value.y * scale, value.z * scale, value.w * scale);
        }

        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
        private static bool Finite(Vector3 value) => Finite(value.x) && Finite(value.y) && Finite(value.z);

        private static readonly HumanBodyBones[] SelectedBones =
        {
            HumanBodyBones.Spine, HumanBodyBones.Chest, HumanBodyBones.UpperChest,
            HumanBodyBones.LeftShoulder, HumanBodyBones.RightShoulder,
            HumanBodyBones.LeftUpperArm, HumanBodyBones.RightUpperArm,
            HumanBodyBones.LeftLowerArm, HumanBodyBones.RightLowerArm,
            HumanBodyBones.LeftHand, HumanBodyBones.RightHand,
            HumanBodyBones.LeftThumbProximal, HumanBodyBones.LeftThumbIntermediate, HumanBodyBones.LeftThumbDistal,
            HumanBodyBones.LeftIndexProximal, HumanBodyBones.LeftIndexIntermediate, HumanBodyBones.LeftIndexDistal,
            HumanBodyBones.LeftMiddleProximal, HumanBodyBones.LeftMiddleIntermediate, HumanBodyBones.LeftMiddleDistal,
            HumanBodyBones.LeftRingProximal, HumanBodyBones.LeftRingIntermediate, HumanBodyBones.LeftRingDistal,
            HumanBodyBones.LeftLittleProximal, HumanBodyBones.LeftLittleIntermediate, HumanBodyBones.LeftLittleDistal,
            HumanBodyBones.RightThumbProximal, HumanBodyBones.RightThumbIntermediate, HumanBodyBones.RightThumbDistal,
            HumanBodyBones.RightIndexProximal, HumanBodyBones.RightIndexIntermediate, HumanBodyBones.RightIndexDistal,
            HumanBodyBones.RightMiddleProximal, HumanBodyBones.RightMiddleIntermediate, HumanBodyBones.RightMiddleDistal,
            HumanBodyBones.RightRingProximal, HumanBodyBones.RightRingIntermediate, HumanBodyBones.RightRingDistal,
            HumanBodyBones.RightLittleProximal, HumanBodyBones.RightLittleIntermediate, HumanBodyBones.RightLittleDistal,
        };
    }
}
