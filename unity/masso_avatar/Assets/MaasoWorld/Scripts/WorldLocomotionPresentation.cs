using UnityEngine;

namespace Maaso.World
{
    public static class WorldLocomotionPresentation
    {
        public const string WorldWalkSpeedParameter = "WorldWalkSpeed";
        public const string WorldWalkStrideParameter = "WorldWalkStride";
        public const float StartDistance = 0.08f;
        public const float StopDistance = 0.025f;
        public const float DefaultWalkingSpeedMultiplier = 1.15f;
        public const float WalkingSpeedMetersPerSecond = 1.6f * DefaultWalkingSpeedMultiplier;
        public const float RotationDegreesPerSecond = 360f;

        private const float DirectionEpsilonSquared = 0.000001f;

        // A direct or stationary walk has no ground-distance contract. Boost
        // its authored gait, rather than calibrating it to navigation's m/s.
        public static void ApplyDefaultWalkingAnimationSpeed(Animator animator)
        {
            ApplyWalkingAnimationSpeed(animator, false);
            if (animator == null || animator.runtimeAnimatorController == null) return;
            int parameterId = Animator.StringToHash(WorldWalkSpeedParameter);
            foreach (AnimatorControllerParameter parameter in animator.parameters)
            {
                if (parameter.nameHash != parameterId || parameter.type != AnimatorControllerParameterType.Float) continue;
                animator.SetFloat(parameterId, DefaultWalkingSpeedMultiplier);
                return;
            }
        }

        public static void ApplyWalkingAnimationSpeed(Animator animator, bool walking,
            float metersPerSecond = WalkingSpeedMetersPerSecond)
        {
            if (animator == null || animator.runtimeAnimatorController == null)
            {
                return;
            }

            // World entry/exit and model replacement must not leave a short
            // world's step amplitude on the next ordinary walk action.
            ApplyWalkingStride(animator, 1f);

            int parameterId = Animator.StringToHash(WorldWalkSpeedParameter);
            bool hasSpeedParameter = false;
            foreach (AnimatorControllerParameter parameter in animator.parameters)
            {
                if (parameter.nameHash == parameterId &&
                    parameter.type == AnimatorControllerParameterType.Float)
                {
                    hasSpeedParameter = true;
                    break;
                }
            }
            if (!hasSpeedParameter)
            {
                return;
            }

            float playbackSpeed = 1f;
            if (walking)
            {
                foreach (AnimationClip clip in animator.runtimeAnimatorController.animationClips)
                {
                    if (clip == null || clip.name != "standard_walk")
                    {
                        continue;
                    }

                    // Humanoid averageSpeed is normalized to the reference avatar.
                    // Convert it to this avatar's world distance before matching navigation.
                    Vector3 velocity = clip.averageSpeed;
                    velocity.y = 0f;
                    velocity = animator.transform.TransformVector(velocity);
                    velocity.y = 0f;
                    float avatarScale = animator.isHuman ? animator.humanScale : 1f;
                    float authoredSpeed = velocity.magnitude * avatarScale;
                    if (IsFinite(authoredSpeed) && authoredSpeed > 0.001f)
                    {
                        playbackSpeed = IsFinite(metersPerSecond)
                            ? Mathf.Max(0f, metersPerSecond) / authoredSpeed : 1f;
                    }
                    break;
                }
            }

            // A clip with no trajectory has no measured speed; retain its authored rate.
            animator.SetFloat(parameterId, playbackSpeed);
        }

        public static void ApplyWalkingStride(Animator animator, float stride)
        {
            if (animator == null || animator.runtimeAnimatorController == null) return;
            int parameterId = Animator.StringToHash(WorldWalkStrideParameter);
            foreach (AnimatorControllerParameter parameter in animator.parameters)
            {
                if (parameter.nameHash != parameterId || parameter.type != AnimatorControllerParameterType.Float) continue;
                animator.SetFloat(parameterId, IsFinite(stride) ? Mathf.Clamp01(stride) : 1f);
                return;
            }
        }

        public static bool ShouldMove(
            Vector3 currentPosition,
            Vector3 targetPosition,
            bool wasMoving)
        {
            Vector3 planar = targetPosition - currentPosition;
            planar.y = 0f;
            float threshold = wasMoving ? StopDistance : StartDistance;
            return IsFinite(planar) && planar.sqrMagnitude > threshold * threshold;
        }

        public static float WalkingStepDurationSeconds(Animator animator)
        {
            if (animator == null || animator.runtimeAnimatorController == null) return 0f;
            bool hasWalkingState = false;
            for (int layer = 0; layer < animator.layerCount; layer++)
                hasWalkingState |= animator.HasState(layer, Animator.StringToHash("standard_walk"));
            // A custom controller can use this clip in a differently named
            // fallback state. Only use a phase clock we can actually observe.
            if (!hasWalkingState) return 0f;
            foreach (AnimationClip clip in animator.runtimeAnimatorController.animationClips)
            {
                if (clip == null || clip.name != "standard_walk") continue;
                float playback = 1f;
                int parameter = Animator.StringToHash(WorldWalkSpeedParameter);
                foreach (AnimatorControllerParameter item in animator.parameters)
                    if (item.nameHash == parameter && item.type == AnimatorControllerParameterType.Float)
                    { playback = animator.GetFloat(parameter); break; }
                float rate = Mathf.Abs(playback * animator.speed);
                if (!IsFinite(rate) || rate < .001f || !IsFinite(clip.length) || clip.length <= 0f) return 0f;
                // The authored walk loop has alternating left/right footfalls.
                // Finish at a half-cycle boundary instead of cutting a short tap
                // back to idle while a foot is still swinging.
                return clip.length * .5f / rate;
            }
            return 0f;
        }

        public static float ArrivalAtStepBoundary(float planarDistance, float elapsed, float stepSeconds)
        {
            float earliest = Mathf.Max(0f, elapsed) + Mathf.Max(0f, planarDistance) / WalkingSpeedMetersPerSecond;
            if (!IsFinite(stepSeconds) || stepSeconds <= .001f) return earliest;
            return Mathf.Max(stepSeconds, Mathf.Ceil(earliest / stepSeconds - .00001f) * stepSeconds);
        }

        public static bool TryGetWalkingPhase(Animator animator, out float normalizedTime)
        {
            normalizedTime = 0f;
            if (animator == null || animator.runtimeAnimatorController == null) return false;
            for (int layer = 0; layer < animator.layerCount; layer++)
            {
                // During CrossFade the next state is the clock for the new
                // stride; the outgoing idle state's duration is unrelated.
                AnimatorStateInfo state = animator.GetNextAnimatorStateInfo(layer);
                if (!animator.IsInTransition(layer))
                    state = animator.GetCurrentAnimatorStateInfo(layer);
                // Do not consume the departing walk while it blends to idle:
                // a rapid new tap can queue a fresh walk starting at phase zero.
                if (!state.IsName("standard_walk") || !IsFinite(state.normalizedTime)) continue;
                normalizedTime = state.normalizedTime;
                return true;
            }
            return false;
        }

        public static Quaternion ResolveFacing(
            Vector3 currentPosition,
            Vector3 targetPosition,
            Quaternion fallback)
        {
            Vector3 planar = targetPosition - currentPosition;
            planar.y = 0f;
            if (!IsFinite(planar) || planar.sqrMagnitude <= DirectionEpsilonSquared)
            {
                return fallback;
            }

            return Quaternion.LookRotation(planar.normalized, Vector3.up);
        }

        public static Vector3 AdvancePosition(
            Vector3 currentPosition,
            Vector3 targetPosition,
            float unscaledDeltaTime)
        {
            return Vector3.MoveTowards(
                currentPosition,
                targetPosition,
                WalkingSpeedMetersPerSecond * Mathf.Max(0f, unscaledDeltaTime));
        }

        public static Quaternion AdvanceRotation(
            Quaternion currentRotation,
            Quaternion targetRotation,
            float unscaledDeltaTime)
        {
            return Quaternion.RotateTowards(
                currentRotation,
                targetRotation,
                RotationDegreesPerSecond * Mathf.Max(0f, unscaledDeltaTime));
        }

        private static bool IsFinite(Vector3 value) =>
            IsFinite(value.x) && IsFinite(value.y) && IsFinite(value.z);

        private static bool IsFinite(float value) =>
            !float.IsNaN(value) && !float.IsInfinity(value);
    }
}
