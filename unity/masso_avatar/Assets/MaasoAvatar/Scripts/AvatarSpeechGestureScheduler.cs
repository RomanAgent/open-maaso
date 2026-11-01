using System;
using System.Collections.Generic;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>
    /// Read-only acoustic choreography on the actual playback cursor. This owns
    /// neither audio nor the avatar: task/explicit-action ownership is supplied
    /// by the receiver. No text, language heuristic or model call is involved.
    /// </summary>
    public sealed class AvatarSpeechGestureScheduler
    {
        public enum GesturePhase { None, Rest, Preparation, Hold, Stroke, Retraction }

        public readonly struct Sample
        {
            public readonly OpenAnnieMotionLibrary.Entry Entry;
            public readonly float ClipSeconds;
            // Lifecycle activity only. Renderers preserve the authored arm/
            // finger pose at gain one and smooth source switches separately.
            public readonly float Weight;
            public readonly GesturePhase Phase;
            public readonly int StrokeIndex;
            public readonly float StrokeOffsetSeconds;
            public bool Active => Entry != null && Weight > 0f;

            public Sample(OpenAnnieMotionLibrary.Entry entry, float clipSeconds, float weight,
                GesturePhase phase, int strokeIndex = -1, float strokeOffsetSeconds = 0f)
            {
                Entry = entry;
                ClipSeconds = clipSeconds;
                Weight = weight;
                Phase = phase;
                StrokeIndex = strokeIndex;
                StrokeOffsetSeconds = strokeOffsetSeconds;
            }
        }

        public const float MaximumHoldSeconds = .6f;
        public const float MinimumAccentIntervalSeconds = 3.2f;
        public static Sample Empty => new(null, 0f, 0f, GesturePhase.None);
        private const float ReleaseSeconds = .18f;
        private const float MaximumContinuousStep = .35f;
        private const float MinimumSound = .055f;
        private const float RestVoicedExitThreshold = .035f;
        public const float RestSilenceHoldSeconds = .15f;
        public const float RestAttackSeconds = .18f;
        public const float RestReleaseSeconds = .28f;
        private readonly List<OpenAnnieMotionLibrary.Entry> gestures = new();
        private readonly List<OpenAnnieMotionLibrary.Entry> rests = new();
        private readonly Dictionary<string, OpenAnnieMotionLibrary.Entry> byId = new(StringComparer.Ordinal);
        private readonly List<float> onsets = new();
        private float[] envelope = Array.Empty<float>();
        private float frameRate;
        private long generation = -1;
        private bool running;
        private float previousPosition = float.NaN;
        private float playedSeconds;
        private float nextGlobalAccent = .7f;
        private float nextLocalAccent = .7f;
        private int selection;
        private int restSelection;
        private OpenAnnieMotionLibrary.Entry active;
        private string queuedId;
        private float activeStartedAt;
        private float[] strokeTimes = Array.Empty<float>();
        private float[] targets = Array.Empty<float>();
        private float[] gates = Array.Empty<float>();
        private float cancelAt = float.PositiveInfinity;
        private float cancelClip;
        private int reportedStroke = -1;
        private bool wasResting;
        private float lastVoicedPosition = float.NegativeInfinity, restGain;
        private string profile = "realistic", energy = "moderate", emotion = "neutral";
        private float activeAccentInterval = MinimumAccentIntervalSeconds;
        private long cueSequence;
        private string lastAutomaticId;

        public long Generation => generation;
        public int AvailableGestureCount => byId.Count;
        public int AvailableRestCount => rests.Count;
        public int AvailableAutomaticGestureCount => gestures.Count;
        public string Profile => profile;
        public string Energy => energy;
        public string Emotion => emotion;
        public long CueSequence => cueSequence;
        public float CurrentAccentIntervalSeconds => AccentInterval();
        public float[] OnsetSeconds => onsets.ToArray();

        public void Initialize(OpenAnnieMotionLibrary library, int seed = 17)
        {
            Stop();
            generation = -1;
            playedSeconds = 0f;
            nextGlobalAccent = .7f;
            gestures.Clear(); rests.Clear(); byId.Clear();
            lastAutomaticId = null;
            selection = seed & int.MaxValue;
            restSelection = selection;
            if (library == null || library.Entries == null) return;
            foreach (var entry in library.Entries)
            {
                if (entry == null || !entry.UpperBody || !Finite(entry.Duration) || entry.Duration <= 0f) continue;
                if (entry.Layer == "gesture" && ValidStages(entry))
                {
                    byId[entry.Id] = entry;
                    // Sound alone supplies timing, never semantic meaning. Both
                    // hands may make a neutral beat even when its author tagged
                    // the source clip excited; profiles select its cadence.
                    if (entry.Category == "beat" && !entry.Contact) gestures.Add(entry);
                }
                else if (entry.Layer == "talk" && entry.Loop &&
                    entry.Energy is "calm" or "animated" or "excited") rests.Add(entry);
            }
        }

        /// <summary>Selected locally from the recognized model, not model text.
        /// No transform, speed or reach scaling is applied by a style profile.</summary>
        public bool SetProfile(string value)
        {
            if (value is not ("realistic" or "restrained" or "cartoony")) return false;
            if (profile != value) { profile = value; ResetPose(); }
            return true;
        }

        /// <summary>Called once after an actual audio-start/track receipt. Older
        /// generations cannot replace the currently playing utterance.</summary>
        public bool Start(long sessionGeneration, float[] track, float trackFrameRate)
        {
            if (sessionGeneration < 0 || sessionGeneration <= generation || track == null ||
                track.Length == 0 || track.Length > 7200 || !Finite(trackFrameRate) ||
                trackFrameRate < 1f || trackFrameRate > 120f) return false;
            generation = sessionGeneration;
            running = true;
            frameRate = trackFrameRate;
            envelope = new float[track.Length];
            for (int i = 0; i < track.Length; i++) envelope[i] = Finite(track[i]) ? Mathf.Clamp01(track[i]) : 0f;
            ExtractOnsets();
            ResetPose();
            previousPosition = float.NaN;
            nextLocalAccent = .7f;
            restSelection = restSelection == int.MaxValue ? 0 : restSelection + 1;
            queuedId = null;
            cueSequence = 0;
            energy = "moderate";
            emotion = "neutral";
            return true;
        }

        /// <summary>Optional high-level cue. No layer is acquired here, and a
        /// missing acoustic onset still prevents an emphasis.</summary>
        public bool QueueGesture(string id)
        {
            if (!running || id == null || !byId.ContainsKey(id)) return false;
            queuedId = id;
            return true;
        }

        /// <summary>
        /// A body-authorized cue for this actual playback generation. A newer
        /// cue replaces only a pending cue; it never interrupts an ongoing
        /// stroke or bypasses the shared accent budget. The receiver owns
        /// authorization, identity binding and any before-audio buffering.
        /// </summary>
        public bool QueuePerformanceCue(long sessionGeneration, long sequence, string gestureId,
            string cueEmotion, string cueEnergy, float cueIntensity)
        {
            bool automatic = string.IsNullOrEmpty(gestureId) || gestureId is "none" or "auto";
            if (!running || sessionGeneration != generation || sequence <= cueSequence ||
                sequence > 9007199254740991L || !Finite(cueIntensity) || cueIntensity < 0f || cueIntensity > 1f ||
                cueEnergy is not ("calm" or "moderate" or "high") ||
                cueEmotion is not ("neutral" or "calm" or "happy" or "excited" or "sad" or
                    "comforting" or "curious" or "thinking" or "surprised" or "angry") ||
                (!automatic && !byId.ContainsKey(gestureId))) return false;
            cueSequence = sequence;
            energy = cueEnergy;
            emotion = cueEmotion;
            queuedId = automatic ? null : gestureId;
            // Retain a running phrase's captured timing and voice gate. Style
            // selects the next source/cadence, never its joint-pose amplitude.
            return true;
        }

        /// <summary>Retire a body lease without retiring the audio session or
        /// its density budget. Keep sequence high-water so release cannot make
        /// a stale cue replayable during this same playback generation.</summary>
        public void ClearPerformanceCue()
        {
            queuedId = null;
            energy = "moderate";
            emotion = "neutral";
            ResetPose();
            if (Finite(previousPosition)) nextLocalAccent = previousPosition + .7f;
        }

        public Sample Tick(long sessionGeneration, float playbackSeconds, bool playing, bool blocked)
        {
            if (!running || sessionGeneration != generation || !Finite(playbackSeconds) || playbackSeconds < 0f)
                return Empty;
            float delta = float.IsNaN(previousPosition) ? 0f : playbackSeconds - previousPosition;
            previousPosition = playbackSeconds;
            if (!playing || blocked || delta < -.025f || delta > MaximumContinuousStep ||
                playbackSeconds >= envelope.Length / frameRate)
            {
                ResetPose();
                // Never perform a queued old sentence's point/contact after a
                // task takeover, seek, pause or disconnected playback resumes.
                queuedId = null;
                nextLocalAccent = playbackSeconds + .7f;
                return Empty;
            }
            playedSeconds += Mathf.Max(0f, delta);
            AdvanceRest(playbackSeconds, Mathf.Max(0f, delta));
            if (active == null) TryBeginGesture(playbackSeconds);
            if (active != null)
            {
                Sample sample = EvaluateGesture(playbackSeconds);
                if (sample.Active) return sample;
            }
            // A sustained mid-level talk posture carries conversation between
            // accents. Unvoiced consonants/brief word gaps are not a new body
            // state; only sustained silence fades this pose to release.
            if (rests.Count == 0 || restGain <= 0f) return Empty;
            var rest = SelectRest();
            return new Sample(rest, playbackSeconds % rest.Duration,
                restGain, GesturePhase.Rest);
        }

        private void AdvanceRest(float position, float delta)
        {
            if (rests.Count == 0) return;
            float sound = SoundAt(position);
            bool voiced = sound >= MinimumSound || (wasResting && sound >= RestVoicedExitThreshold);
            if (voiced)
            {
                lastVoicedPosition = Mathf.Max(lastVoicedPosition, position);
                if (!wasResting)
                {
                    wasResting = true;
                }
            }
            bool hold = wasResting && position - lastVoicedPosition <= RestSilenceHoldSeconds;
            restGain = Mathf.MoveTowards(restGain, hold ? 1f : 0f,
                delta / (hold ? RestAttackSeconds : RestReleaseSeconds));
            // This gain only owns the episode lifetime. It is never a joint
            // amplitude or a blend from authored hands-front into hands-down.
            if (!hold && restGain <= 0f) wasResting = false;
        }

        public void Stop()
        {
            running = false;
            envelope = Array.Empty<float>();
            onsets.Clear();
            queuedId = null;
            cueSequence = 0;
            ResetPose();
            previousPosition = float.NaN;
        }

        private void TryBeginGesture(float position)
        {
            OpenAnnieMotionLibrary.Entry chosen = null;
            if (queuedId != null) byId.TryGetValue(queuedId, out chosen);
            bool semantic = chosen != null;
            if (chosen == null) chosen = SelectAutomaticGesture();
            if (chosen == null) return;
            float firstStroke = FirstStroke(chosen);
            float earliest = Mathf.Max(position + firstStroke, nextLocalAccent,
                position + Mathf.Max(0f, nextGlobalAccent - playedSeconds));
            float target = FindOnset(earliest, position + firstStroke + MaximumHoldSeconds);
            if (target < 0f) return;
            active = chosen;
            activeAccentInterval = AccentInterval();
            activeStartedAt = position;
            selection = selection == int.MaxValue ? 0 : selection + 1;
            if (!semantic) lastAutomaticId = chosen.Id;
            queuedId = null;
            strokeTimes = StrokeTimes(chosen);
            targets = new float[strokeTimes.Length];
            gates = new float[strokeTimes.Length];
            float hold = 0f;
            cancelAt = float.PositiveInfinity;
            reportedStroke = -1;
            for (int i = 0; i < strokeTimes.Length; i++)
            {
                gates[i] = i == 0 ? chosen.PreparationEnd : Mathf.Max(strokeTimes[i - 1] + .06f, strokeTimes[i] - .12f);
                float earliestStroke = position + strokeTimes[i] + hold;
                targets[i] = i == 0 ? target : FindOnset(earliestStroke, earliestStroke + MaximumHoldSeconds);
                if (targets[i] < 0f)
                {
                    cancelAt = position + gates[i] + hold;
                    cancelClip = gates[i];
                    targets[i] = float.PositiveInfinity;
                    break;
                }
                hold += Mathf.Max(0f, targets[i] - earliestStroke);
            }
        }

        private Sample EvaluateGesture(float position)
        {
            float elapsed = position - activeStartedAt;
            float hold = 0f;
            float clip = elapsed;
            var phase = GesturePhase.Preparation;
            int stroke = -1;
            float strokeOffset = 0f;
            if (position >= cancelAt)
            {
                float weight = 1f - Mathf.Clamp01((position - cancelAt) / ReleaseSeconds);
                if (weight <= 0f) { FinishGesture(position); return Empty; }
                return new Sample(active, cancelClip, weight, GesturePhase.Retraction);
            }
            for (int i = 0; i < strokeTimes.Length; i++)
            {
                float gateAt = activeStartedAt + gates[i] + hold;
                float releaseAt = targets[i] - (strokeTimes[i] - gates[i]);
                if (position < gateAt) { clip = elapsed - hold; break; }
                if (position < releaseAt)
                    return new Sample(active, gates[i], 1f, GesturePhase.Hold);
                hold += Mathf.Max(0f, releaseAt - gateAt);
                clip = elapsed - hold;
                phase = GesturePhase.Stroke;
                if (i > reportedStroke && position >= targets[i])
                {
                    reportedStroke = i;
                    stroke = i;
                    strokeOffset = position - targets[i];
                    nextGlobalAccent = playedSeconds + activeAccentInterval;
                }
            }
            if (clip >= active.Duration) { FinishGesture(position); return Empty; }
            if (clip >= active.RetractionStart) phase = GesturePhase.Retraction;
            float fadeIn = Mathf.SmoothStep(0f, 1f, elapsed / .12f);
            float fadeOut = Mathf.SmoothStep(0f, 1f, (active.Duration - clip) / ReleaseSeconds);
            return new Sample(active, Mathf.Max(0f, clip), Mathf.Min(fadeIn, fadeOut), phase, stroke, strokeOffset);
        }

        private string EffectiveEnergy() => emotion is "sad" or "comforting" or "thinking" or "calm" ? "calm" : energy;

        private float AccentInterval()
        {
            float interval = EffectiveEnergy() switch { "calm" => 4.2f, "high" => 2.7f, _ => MinimumAccentIntervalSeconds };
            if (profile == "restrained") interval += .6f;
            else if (profile == "cartoony") interval -= .3f;
            return Mathf.Max(2.4f, interval);
        }

        private OpenAnnieMotionLibrary.Entry SelectRest()
        {
            string desired = EffectiveEnergy() switch
            { "calm" => "calm", "high" when profile == "cartoony" => "excited", _ => "animated" };
            int count = 0;
            foreach (var entry in rests) if (entry.Energy == desired) count++;
            if (count == 0) return rests[restSelection % rests.Count];
            int selected = restSelection % count;
            foreach (var entry in rests) if (entry.Energy == desired && selected-- == 0) return entry;
            return rests[0];
        }

        private OpenAnnieMotionLibrary.Entry SelectAutomaticGesture()
        {
            if (gestures.Count == 0) return null;
            string level = EffectiveEnergy();
            OpenAnnieMotionLibrary.Entry fallback = null;
            for (int offset = 0; offset < gestures.Count; offset++)
            {
                var candidate = gestures[(int)(((long)selection + offset) % gestures.Count)];
                bool allowed = level switch
                {
                    "calm" => candidate.Energy != "excited",
                    "high" => true,
                    _ => candidate.Energy != "excited" || candidate.Hands == "both",
                };
                if (!allowed) continue;
                fallback ??= candidate;
                if (candidate.Id == lastAutomaticId && gestures.Count > 1) continue;
                return candidate;
            }
            return fallback;
        }

        private void FinishGesture(float position)
        {
            active = null;
            nextLocalAccent = position + 1.2f;
        }

        private void ResetPose()
        {
            active = null;
            reportedStroke = -1;
            wasResting = false;
            restGain = 0f;
            lastVoicedPosition = float.NegativeInfinity;
        }

        private void ExtractOnsets()
        {
            onsets.Clear();
            int lookback = Mathf.Max(1, Mathf.RoundToInt(frameRate * .08f));
            float previousOnset = -1f;
            for (int i = 1; i < envelope.Length; i++)
            {
                float rise = envelope[i] - envelope[Mathf.Max(0, i - lookback)];
                float at = i / frameRate;
                if (envelope[i] >= .11f && rise >= .055f && at - previousOnset >= .22f)
                {
                    onsets.Add(at);
                    previousOnset = at;
                }
            }
        }

        private float FindOnset(float earliest, float latest)
        {
            foreach (float onset in onsets)
            {
                if (onset + .00001f < earliest) continue;
                return onset <= latest + .00001f ? onset : -1f;
            }
            return -1f;
        }

        private float SoundAt(float position) => envelope.Length == 0 ? 0f :
            envelope[Mathf.Clamp(Mathf.FloorToInt(position * frameRate), 0, envelope.Length - 1)];

        private static bool ValidStages(OpenAnnieMotionLibrary.Entry entry)
        {
            if (string.IsNullOrEmpty(entry.Id) || !Finite(entry.PreparationEnd) ||
                !Finite(entry.RetractionStart) || entry.PreparationEnd < 0f ||
                entry.RetractionStart >= entry.Duration) return false;
            float previous = entry.PreparationEnd;
            foreach (float stroke in StrokeTimes(entry))
            {
                if (!Finite(stroke) || stroke <= previous || stroke >= entry.RetractionStart) return false;
                previous = stroke;
            }
            return true;
        }

        private static float FirstStroke(OpenAnnieMotionLibrary.Entry entry) =>
            entry.Strokes != null && entry.Strokes.Length > 0 ? entry.Strokes[0] : entry.Stroke;
        private static float[] StrokeTimes(OpenAnnieMotionLibrary.Entry entry) =>
            entry.Strokes != null && entry.Strokes.Length > 0 ? entry.Strokes : new[] { entry.Stroke };
        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
    }
}
