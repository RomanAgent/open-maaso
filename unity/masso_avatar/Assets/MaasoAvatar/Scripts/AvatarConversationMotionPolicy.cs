using System;
using System.Collections.Generic;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>
    /// Low-priority local idle/listen choices. Real task ownership and admitted
    /// body commands must gate Advance; this policy never writes an Animator.
    /// </summary>
    public sealed class AvatarConversationMotionPolicy
    {
        public sealed class Decision
        {
            public string ClipId;
            public float NormalizedTime;
            public float HoldSeconds;
            public bool IsFidget;
        }

        public const float PhaseHysteresisSeconds = .35f;
        public const float StableIdleBeforeFidgetSeconds = 8f;
        public const string BaseIdleState = "idle_shrug";
        private sealed class LoopMemory { public string Id; public float Phase, Duration = 1f; }
        private readonly Dictionary<string, LoopMemory> loops = new();
        private readonly HashSet<string> unavailable = new(StringComparer.Ordinal);
        private readonly uint initialSeed;
        private uint randomState;
        private string desiredPhase = "idle", phase = "idle", activeId;
        private float desiredSince, stableSince, activeAt, activePhase, activeDuration, activeEndsAt;
        private float nextChoiceAt, nextFidgetAt, lastNow = float.NegativeInfinity;
        private bool activeLoop, suspended;
        private Decision pending;

        public AvatarConversationMotionPolicy(int seed = 1729)
        {
            randomState = initialSeed = seed == 0 ? 1729u : unchecked((uint)seed);
        }

        public string Phase => phase;
        public string ActiveId => activeId;
        // The receiver retains the admitted clip until its player releases it,
        // even if a phase hint has already cleared this policy's active record.
        public static bool IsInterlude(string clipId) => Array.IndexOf(Fidgets, clipId) >= 0;

        public void SetPhase(string value, float now)
        {
            if (!Finite(now)) return;
            value = value?.Trim().ToLowerInvariant();
            value = value switch
            {
                "listen" or "listening" => "listening",
                "speaking" => "speaking",
                "thinking" => "thinking",
                "idle" or "stopped" or "none" => "idle",
                _ => null,
            };
            if (value == null || value == desiredPhase) return;
            desiredPhase = value;
            desiredSince = now;
            // Any real conversation activity restarts the stable silence window,
            // even if a brief phase never passes the presentation hysteresis.
            stableSince = now;
        }

        public Decision Advance(float now, bool blocked, bool bodyActionActive)
        {
            if (!Finite(now)) return null;
            if (now < lastNow) Reset(now);
            lastNow = now;
            if (blocked || bodyActionActive)
            {
                SaveLoop(now);
                activeId = null;
                pending = null;
                suspended = true;
                stableSince = now;
                nextChoiceAt = now + PhaseHysteresisSeconds;
                return null;
            }
            if (suspended)
            {
                suspended = false;
                stableSince = now;
                nextChoiceAt = now + PhaseHysteresisSeconds;
            }
            if (phase != desiredPhase)
            {
                if (now - desiredSince < PhaseHysteresisSeconds) return null;
                SaveLoop(now);
                phase = desiredPhase;
                activeId = null;
                pending = null;
            }
            if (phase is not ("idle" or "listening") || desiredPhase != phase || pending != null || now < nextChoiceAt)
                return null;
            if (activeId != null && !activeLoop && now < activeEndsAt) return null;
            if (activeId != null && !activeLoop) activeId = null;
            if (activeId != null)
            {
                // Quiet, infrequent fidgets only. No fidget while listening or
                // during tiny speaking gaps, and never repeated every idle tick.
                if (phase != "idle" || now - stableSince < StableIdleBeforeFidgetSeconds || now < nextFidgetAt) return null;
                nextFidgetAt = now + 12f + NextFloat() * 8f;
                if (NextFloat() >= .55f) return null;
                string fidget = PickAvailable(Fidgets);
                if (fidget != null) return pending = new Decision { ClipId = fidget, HoldSeconds = 8f, IsFidget = true };
                return null;
            }
            if (!loops.TryGetValue(phase, out LoopMemory memory) || unavailable.Contains(memory.Id))
            {
                // The reviewed native standing clip owns the neutral base.
                // Annie's named idles retain stylized arm and finger poses;
                // their names are not evidence of a relaxed human stance.
                string id = PickAvailable(Idles);
                if (id == null) return null;
                loops[phase] = memory = new LoopMemory { Id = id };
            }
            return pending = new Decision { ClipId = memory.Id, NormalizedTime = memory.Phase, HoldSeconds = 30f };
        }

        /// <summary>Only after actual playback succeeds; own policy motions are
        /// excluded from the caller's bodyActionActive gate.</summary>
        public void NotifyPlayed(string id, float now, float duration, bool loop)
        {
            if (pending == null || pending.ClipId != id || !Finite(now) || !Finite(duration) || duration <= 0f) return;
            SaveLoop(now);
            activeId = id;
            activeAt = now;
            activePhase = pending.NormalizedTime;
            activeDuration = duration;
            // Source loop metadata describes the asset, not this admission's
            // lifetime. A looping idle used as a fidget still ends after one
            // authored cycle and returns to the retained neutral base.
            activeLoop = loop && !pending.IsFidget;
            activeEndsAt = now + duration;
            if (!pending.IsFidget && loops.TryGetValue(phase, out LoopMemory memory)) memory.Duration = duration;
            pending = null;
        }

        public void Reject(string id, float now)
        {
            if (string.IsNullOrEmpty(id) || !Finite(now)) return;
            unavailable.Add(id);
            if (pending?.ClipId == id) pending = null;
            if (activeId == id) activeId = null;
            nextChoiceAt = now + .25f;
        }

        /// <summary>Notify when the bounded player actually ends this policy's
        /// own clip. Renew at the retained phase, never by silently assuming an
        /// expired 30-second command is still playing.</summary>
        public void PlaybackEnded(float now)
        {
            if (!Finite(now)) return;
            SaveLoop(now);
            activeId = null;
            pending = null;
        }

        public void Reset(float now = 0f)
        {
            activeId = null;
            activeLoop = false;
            pending = null;
            loops.Clear();
            unavailable.Clear();
            desiredPhase = phase = "idle";
            desiredSince = stableSince = now;
            nextChoiceAt = now + PhaseHysteresisSeconds;
            nextFidgetAt = now + StableIdleBeforeFidgetSeconds;
            lastNow = now;
            suspended = false;
            randomState = initialSeed;
        }

        private void SaveLoop(float now)
        {
            if (activeId == null || !activeLoop || activeDuration <= 0f ||
                !loops.TryGetValue(phase, out LoopMemory memory) || memory.Id != activeId) return;
            memory.Phase = Mathf.Repeat(activePhase + Mathf.Max(0f, now - activeAt) / activeDuration, 1f);
            activePhase = memory.Phase;
            activeAt = now;
        }

        private string PickAvailable(string[] pool)
        {
            int start = (int)(NextUInt() % (uint)pool.Length);
            for (int i = 0; i < pool.Length; i++)
            {
                string id = pool[(start + i) % pool.Length];
                if (!unavailable.Contains(id)) return id;
            }
            return null;
        }

        private uint NextUInt()
        {
            randomState ^= randomState << 13;
            randomState ^= randomState >> 17;
            randomState ^= randomState << 5;
            return randomState;
        }
        private float NextFloat() => (NextUInt() & 0x00ffffffu) / 16777216f;
        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
        private static readonly string[] Idles = { BaseIdleState };
        // Deliberately omit foot rocking and large stretches. Those alter leg
        // contact or overlap clothing more than a low-priority micro gesture.
        private static readonly string[] Fidgets = { "annie_fidget_hair", "annie_fidget_sleeve", "annie_fidget_clasp", "annie_fidget_glance", "annie_idle_c" };
    }
}
