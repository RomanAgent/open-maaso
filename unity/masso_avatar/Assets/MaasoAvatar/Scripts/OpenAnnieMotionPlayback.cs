using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Local playback only. Task, navigation, gaze and speech remain owned by their existing controllers.</summary>
    public sealed class OpenAnnieMotionPlayback
    {
        public const string Prefix = "annie_";
        private const float FadeIn = .12f;
        private const float FadeOut = .2f;
        private OpenAnnieMotionLibrary library;
        private Animator animator;
        private int upperLayer = -1;
        private float startedAt;
        private float endsAt;
        private bool upperBody;
        // CrossFade requests need not appear in AnimatorStateInfo until its
        // next evaluation. Remember the last queued body source across Stop,
        // which releases ownership without cancelling that pending transition.
        private bool lastBodySelectionWasBase = true;
        public string ActiveId { get; private set; }
        // A repeated clip is a new source episode even when its name is unchanged.
        public long EpisodeId { get; private set; }
        public bool Active => ActiveId != null;
        public float Remaining(float now) => Active ? Mathf.Max(0f, endsAt - now) : 0f;

        public static string SemanticClip(string gesture) => gesture switch
        {
            "wave" or "soft_wave" => "annie_wave",
            "clap" => "annie_clap",
            "shrug" => "annie_shrug",
            "think" or "thinking" => "annie_think",
            "laugh" => "annie_laugh",
            "bow" => "annie_bow",
            "point_self" => "annie_point_self",
            "cheer" => "annie_excited_bounce",
            "dance" => "annie_dance",
            "explain" => "annie_g_roll_both",
            "palms_open" => "annie_g_open_both",
            "point_small" => "annie_g_point_r",
            "chest" or "hand_to_chest" => "annie_g_chest_r",
            _ => null,
        };

        public bool HasClip(string id)
        {
            library ??= Resources.Load<OpenAnnieMotionLibrary>("OpenAnnieMotionLibrary");
            return library != null && library.TryGet(id, out _);
        }

        public string FallbackMotion(string id)
        {
            if (!HasClip(id)) return null;
            return id switch
            {
                "annie_wave" => "wave",
                "annie_clap" => "clap",
                "annie_shrug" => "shrug",
                "annie_think" => "think",
                "annie_laugh" => "laugh",
                "annie_sad_slump" => "sad",
                "annie_surprised_recoil" => "startled",
                "annie_bow" => "bow",
                "annie_point_self" => "hand_to_chest",
                "annie_excited_bounce" => "cheer",
                "annie_dance" => "hip_hop_dance",
                _ => id.StartsWith("annie_g_") ? "explain" : "listen",
            };
        }

        public bool TryPlay(Animator target, string id, float now, bool blocked, float requestedSeconds = 0f)
        {
            if (blocked || target == null || !target.isHuman || !target.isActiveAndEnabled ||
                target.runtimeAnimatorController == null || !HasClip(id) || !library.TryGet(id, out var entry))
                return false;
            int layer = entry.UpperBody ? target.GetLayerIndex(OpenAnnieMotionLibrary.UpperBodyLayerName) : 0;
            int state = Animator.StringToHash((entry.UpperBody ? OpenAnnieMotionLibrary.UpperBodyLayerName : target.GetLayerName(0)) + "." + id);
            if (layer < 0 || !target.HasState(layer, state)) return false;
            // An upper-body replacement must not leave a previous dance or
            // whole-body one-shot playing underneath it. Ownership loss itself
            // never resets layer zero, since a task may already have taken it.
            if (entry.UpperBody && Active && !upperBody && animator == target)
            {
                int idle = Animator.StringToHash(target.GetLayerName(0) + ".idle_shrug");
                if (target.HasState(0, idle))
                {
                    target.CrossFadeInFixedTime(idle, FadeIn, 0, 0f);
                    lastBodySelectionWasBase = true;
                }
            }
            Stop();
            animator = target;
            upperLayer = target.GetLayerIndex(OpenAnnieMotionLibrary.UpperBodyLayerName);
            upperBody = entry.UpperBody;
            if (!upperBody) lastBodySelectionWasBase = false;
            ActiveId = id;
            EpisodeId++;
            startedAt = now;
            // A one-shot must not be cut short by the generic 1.2s primitive hold.
            // Loops are bounded by the command lifetime instead of becoming permanent.
            float duration = entry.Loop && requestedSeconds > 0f ? requestedSeconds :
                Mathf.Max(entry.Duration, requestedSeconds);
            endsAt = now + Mathf.Clamp(duration, .2f, 30f);
            if (upperBody) animator.SetLayerWeight(upperLayer, 0f);
            animator.CrossFadeInFixedTime(state, FadeIn, layer, 0f);
            return true;
        }

        /// <summary>The native neutral base shares this bounded ownership
        /// lease, without sampling any normalized Annie arm/finger source.
        /// Renewing a playing/entering native state preserves its real phase.</summary>
        public bool TryPlayBaseIdle(Animator target, string stateName, float now, bool blocked, float requestedSeconds = 30f)
        {
            if (blocked || target == null || !target.isHuman || !target.isActiveAndEnabled ||
                target.runtimeAnimatorController == null || string.IsNullOrEmpty(stateName) ||
                float.IsNaN(now) || float.IsInfinity(now) || float.IsNaN(requestedSeconds) ||
                float.IsInfinity(requestedSeconds) || requestedSeconds <= 0f) return false;
            int state = Animator.StringToHash(target.GetLayerName(0) + "." + stateName);
            if (!target.HasState(0, state)) return false;
            bool transitioning = target.IsInTransition(0);
            bool preservePhase = lastBodySelectionWasBase && (transitioning
                ? target.GetNextAnimatorStateInfo(0).fullPathHash == state
                : target.GetCurrentAnimatorStateInfo(0).fullPathHash == state);
            Stop();
            animator = target;
            upperLayer = target.GetLayerIndex(OpenAnnieMotionLibrary.UpperBodyLayerName);
            upperBody = false;
            lastBodySelectionWasBase = true;
            ActiveId = stateName;
            EpisodeId++;
            startedAt = now;
            endsAt = now + Mathf.Clamp(requestedSeconds, .2f, 30f);
            if (!preservePhase) target.CrossFadeInFixedTime(state, FadeOut, 0, 0f);
            return true;
        }

        /// <returns>True when this playback released ownership this frame.</returns>
        public bool TryPlayAtPhase(Animator target, string id, float now, bool blocked, float requestedSeconds, float normalizedTime)
        {
            if (float.IsNaN(normalizedTime) || float.IsInfinity(normalizedTime) ||
                !TryPlay(target, id, now, blocked, requestedSeconds) || !library.TryGet(id, out var entry)) return false;
            int layer = entry.UpperBody ? target.GetLayerIndex(OpenAnnieMotionLibrary.UpperBodyLayerName) : 0;
            int state = Animator.StringToHash(target.GetLayerName(layer) + "." + id);
            target.CrossFadeInFixedTime(state, FadeIn, layer, Mathf.Repeat(normalizedTime, 1f) * entry.Duration);
            return true;
        }

        /// <returns>True when this playback released ownership this frame.</returns>
        public bool Advance(Animator current, float now, bool blocked)
        {
            if (!Active) return false;
            if (blocked || animator == null || current != animator ||
                !animator.isActiveAndEnabled || now >= endsAt)
            {
                Stop();
                return true;
            }
            if (upperBody && upperLayer >= 0)
            {
                float enter = Mathf.Clamp01((now - startedAt) / FadeIn);
                float exit = Mathf.Clamp01((endsAt - now) / FadeOut);
                animator.SetLayerWeight(upperLayer, Mathf.SmoothStep(0f, 1f, Mathf.Min(enter, exit)));
            }
            return false;
        }

        public void Stop()
        {
            if (animator != null && upperLayer >= 0 && upperLayer < animator.layerCount)
            {
                animator.SetLayerWeight(upperLayer, 0f);
                int empty = Animator.StringToHash(OpenAnnieMotionLibrary.UpperBodyLayerName + "." + OpenAnnieMotionLibrary.EmptyUpperBodyState);
                if (animator.HasState(upperLayer, empty)) animator.Play(empty, upperLayer, 0f);
            }
            animator = null;
            ActiveId = null;
            upperLayer = -1;
            endsAt = 0f;
        }
    }
}
