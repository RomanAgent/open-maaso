using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>
    /// Keeps the actor's logical heading independent of its authored native
    /// idle. Shared Humanoid clips already use canonical forward. Only blend
    /// the native clip's measured whole-model correction, never individual bones.
    /// </summary>
    public sealed class AvatarSourcePresentationFacing : MonoBehaviour
    {
        private Transform model;
        private Animator animator;
        private AnimationClip nativeIdle;
        private Quaternion nativeCorrection;

        public void Initialize(Transform sourceModel, Animator sourceAnimator,
            AnimationClip sourceIdle, Quaternion correction)
        {
            model = sourceModel;
            animator = sourceAnimator;
            nativeIdle = sourceIdle;
            nativeCorrection = correction;
            model.localRotation = correction;
        }

        public void Apply()
        {
            if (model == null || animator == null || nativeIdle == null ||
                !animator.isActiveAndEnabled || animator.runtimeAnimatorController == null)
                return;

            // Unity's clip weights already include the current/next crossfade.
            // Task ownership may release source FK while this heading remains
            // necessary, so do not use SourceIdleBaselineAllowed or FK Weight.
            float weight = Contribution(animator.GetCurrentAnimatorClipInfo(0));
            if (animator.IsInTransition(0))
                weight += Contribution(animator.GetNextAnimatorClipInfo(0));
            model.localRotation = Quaternion.Slerp(
                Quaternion.identity, nativeCorrection, Mathf.Clamp01(weight));
        }

        private float Contribution(AnimatorClipInfo[] clips)
        {
            float weight = 0f;
            foreach (AnimatorClipInfo clip in clips)
                if (clip.clip == nativeIdle) weight += clip.weight;
            return weight;
        }
    }
}
