using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Applies only a scheduler-owned upper-body state. Releasing a
    /// stale owner never clears a newer explicit action on the same layer.</summary>
    public sealed class AvatarSpeechGestureAnimator
    {
        private Animator animator;
        private int layer = -1;
        private int ownedState;
        private string activeId;
        public string ActiveId => activeId;
        public AvatarSpeechGestureScheduler.Sample CurrentSample { get; private set; }
        public bool UsesDirectSource { get; private set; }

        /// <summary>Bookkeeping for the receiver's exclusive normalized source
        /// owner. It releases only this adapter's previous native layer. The
        /// receiver applies the source pose before source-switch inertia.</summary>
        public bool ApplyDirectSource(Animator target, AvatarSpeechGestureScheduler.Sample sample, bool blocked)
        {
            if (blocked || !sample.Active || target == null || !target.isActiveAndEnabled ||
                !target.isHuman || sample.Entry == null || !sample.Entry.UpperBody ||
                !Finite(sample.Entry.Duration) || sample.Entry.Duration <= 0f || !Finite(sample.ClipSeconds) ||
                sample.ClipSeconds < 0f || sample.ClipSeconds > sample.Entry.Duration || !Finite(sample.Weight) ||
                sample.Weight < 0f || sample.Weight > 1f)
            { Release(); return false; }
            if (!UsesDirectSource || animator != target) Release();
            animator = target;
            layer = -1;
            ownedState = 0;
            activeId = sample.Entry.Id;
            CurrentSample = sample;
            UsesDirectSource = true;
            return true;
        }

        public bool Apply(Animator target, AvatarSpeechGestureScheduler.Sample sample, bool blocked)
        {
            if (blocked || !sample.Active || target == null || !target.isActiveAndEnabled ||
                !target.isHuman || target.runtimeAnimatorController == null || sample.Entry == null ||
                !Finite(sample.Entry.Duration) || sample.Entry.Duration <= 0f || !Finite(sample.ClipSeconds) ||
                sample.ClipSeconds < 0f || sample.ClipSeconds > sample.Entry.Duration || !Finite(sample.Weight) ||
                sample.Weight < 0f || sample.Weight > 1f)
            { Release(); return false; }
            int targetLayer = target.GetLayerIndex(OpenAnnieMotionLibrary.UpperBodyLayerName);
            int state = Animator.StringToHash(OpenAnnieMotionLibrary.UpperBodyLayerName + "." + sample.Entry.Id);
            if (targetLayer < 0 || !sample.Entry.UpperBody || !target.HasState(targetLayer, state))
            { Release(); return false; }
            if (animator != target) Release();
            animator = target;
            layer = targetLayer;
            ownedState = state;
            activeId = sample.Entry.Id;
            CurrentSample = sample;
            UsesDirectSource = false;
            // A local audio cursor drives this layer only; Animator.speed and
            // the navigation/base layer are deliberately untouched.
            target.Play(state, layer, sample.ClipSeconds / sample.Entry.Duration);
            // Sample.Weight gates lifetime only. Diluting the whole upper-body
            // pose against an unrelated hands-down idle changes authored elbow/
            // wrist/finger relationships. Entry/exit use source-switch inertia.
            target.SetLayerWeight(layer, 1f);
            return true;
        }

        public void Release()
        {
            if (animator != null && layer >= 0 && layer < animator.layerCount)
            {
                var current = animator.GetCurrentAnimatorStateInfo(layer);
                var next = animator.GetNextAnimatorStateInfo(layer);
                // An explicit action can acquire this same layer between ticks.
                // Its transition/state must survive the old speech release.
                bool mine = animator.IsInTransition(layer) ? next.fullPathHash == ownedState : current.fullPathHash == ownedState;
                if (mine)
                {
                    animator.SetLayerWeight(layer, 0f);
                    int empty = Animator.StringToHash(OpenAnnieMotionLibrary.UpperBodyLayerName + "." + OpenAnnieMotionLibrary.EmptyUpperBodyState);
                    if (animator.HasState(layer, empty)) animator.Play(empty, layer, 0f);
                }
            }
            animator = null;
            layer = -1;
            ownedState = 0;
            activeId = null;
            CurrentSample = AvatarSpeechGestureScheduler.Empty;
            UsesDirectSource = false;
        }

        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
    }
}
