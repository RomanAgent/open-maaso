using System;
using System.Collections.Generic;
using System.IO;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Maaso.Avatar
{
    [Serializable]
    public sealed class AvatarSpeechPlaybackClockPacket
    {
        public int protocolVersion;
        public string playbackId;
        public long generation, sequence;
        public string turnId, utteranceId, state, source;
        public long positionMs;
        public long durationMs;
        public bool authoritative;
        public float[] envelope;
        public int frameRate;

        public static bool TryParse(string json, out AvatarSpeechPlaybackClockPacket packet)
        {
            packet = null;
            if (string.IsNullOrEmpty(json) || json.Length > 192 * 1024) return false;
            try
            {
                using var reader = new JsonTextReader(new StringReader(json)) { DateParseHandling = DateParseHandling.None };
                var obj = JObject.Load(reader, new JsonLoadSettings { DuplicatePropertyNameHandling = DuplicatePropertyNameHandling.Error });
                if (reader.Read()) return false;
                var required = new HashSet<string> { "protocolVersion", "playbackId", "generation", "turnId", "utteranceId", "sequence", "state", "positionMs", "source", "authoritative" };
                foreach (var property in obj.Properties())
                    if (!required.Contains(property.Name) && property.Name is not "durationMs" and not "envelope" and not "frameRate") return false;
                foreach (string field in required) if (obj[field] == null) return false;
                foreach (string field in new[] { "protocolVersion", "generation", "sequence", "positionMs" })
                    if (obj[field].Type != JTokenType.Integer) return false;
                foreach (string field in new[] { "playbackId", "turnId", "utteranceId", "state", "source" })
                    if (obj[field].Type != JTokenType.String) return false;
                if (obj["authoritative"].Type != JTokenType.Boolean ||
                    (obj["durationMs"] != null && obj["durationMs"].Type != JTokenType.Integer) ||
                    (obj["frameRate"] != null && obj["frameRate"].Type != JTokenType.Integer)) return false;
                if (obj["envelope"] != null)
                {
                    if (obj["envelope"] is not JArray samples || samples.Count is < 1 or > 7200) return false;
                    foreach (JToken sample in samples)
                        if (sample.Type is not JTokenType.Integer and not JTokenType.Float ||
                            !FiniteUnit(sample.Value<double>())) return false;
                }
                packet = obj.ToObject<AvatarSpeechPlaybackClockPacket>();
                return packet != null && packet.Valid();
            }
            catch (Exception e) when (e is JsonException or OverflowException or FormatException or ArgumentException)
            { packet = null; return false; }
        }

        public bool Valid()
        {
            if (protocolVersion != 1 || !BoundedId(playbackId) || !BoundedId(turnId) || !BoundedId(utteranceId) ||
                generation < 0 || generation > 9007199254740991L || sequence < 1 || sequence > 9007199254740991L ||
                positionMs < 0 || positionMs > 86400000L || durationMs < 0 || durationMs > 86400000L ||
                (durationMs > 0 && positionMs > durationMs + 2000L) ||
                state is not "start" and not "update" and not "pause" and not "resume" and not "stop" ||
                source is not "wav" and not "pcm" and not "system" || (source == "system" && authoritative)) return false;
            if (envelope == null) return frameRate == 0;
            if (state != "start" || envelope.Length is < 1 or > 7200 || frameRate is < 1 or > 120) return false;
            foreach (float value in envelope) if (!FiniteUnit(value)) return false;
            return true;
        }
        private static bool FiniteUnit(double value) => !double.IsNaN(value) && !double.IsInfinity(value) && value >= 0 && value <= 1;
        private static bool BoundedId(string value)
        {
            if (string.IsNullOrWhiteSpace(value) || value.Length > 160) return false;
            foreach (char c in value) if (char.IsControl(c)) return false;
            return true;
        }
    }

    /// <summary>Consumes sparse real playback receipts; never claims a synthesis or enqueue event is sound.</summary>
    public sealed class AvatarSpeechPlaybackClock
    {
        private const float MaximumPredictionSeconds = .65f;
        private readonly HashSet<string> retired = new();
        private readonly Queue<string> retiredOrder = new();
        private readonly Dictionary<string, long> generationWatermarks = new();
        private float position, receivedAt, duration, correction;
        private bool playing;
        private long sequence;
        public string PlaybackId { get; private set; }
        public long Generation { get; private set; }
        public long Epoch { get; private set; }
        public bool Active => PlaybackId != null;
        public bool Paused { get; private set; }
        public bool Authoritative { get; private set; }
        public float[] Envelope { get; private set; }
        public int FrameRate { get; private set; }
        private string turnId, utteranceId, source;

        public bool Apply(AvatarSpeechPlaybackClockPacket packet, float now)
        {
            if (packet == null || !packet.Valid() || float.IsNaN(now) || float.IsInfinity(now)) return false;
            float previousPrediction = Position(now);
            float measured = packet.positionMs / 1000f;
            bool correcting = Active && packet.state == "update" && playing && !Paused && IsPlaying(now);
            bool stalled = packet.state == "update" && measured <= position;
            if (packet.state == "start")
            {
                if (retired.Contains(packet.playbackId) || packet.playbackId == PlaybackId ||
                    (generationWatermarks.TryGetValue(packet.source, out long watermark) && packet.generation < watermark)) return false;
                RetireCurrent();
                PlaybackId = packet.playbackId;
                Generation = packet.generation;
                turnId = packet.turnId; utteranceId = packet.utteranceId; source = packet.source;
                generationWatermarks[source] = packet.generation;
                Epoch++;
                Envelope = packet.envelope == null ? null : (float[])packet.envelope.Clone();
                FrameRate = packet.frameRate;
                duration = 0f;
            }
            else if (!Active || packet.playbackId != PlaybackId || packet.generation != Generation ||
                packet.sequence <= sequence || packet.turnId != turnId || packet.utteranceId != utteranceId || packet.source != source)
                return false;
            sequence = packet.sequence;
            position = measured;
            if (packet.durationMs > 0) duration = packet.durationMs / 1000f;
            receivedAt = now;
            Authoritative = packet.authoritative;
            Paused = packet.state == "pause" || (Paused && packet.state == "update");
            playing = !Paused && !stalled && (packet.state is "start" or "update" or "resume");
            float difference = previousPrediction - measured;
            // Smooth small native-cursor corrections locally. Large jumps and
            // pause/stop follow the authoritative receipt immediately.
            correction = correcting && playing && Mathf.Abs(difference) <= .125f ? difference : 0f;
            if (packet.state == "stop") RetireCurrent();
            return true;
        }

        public bool IsPlaying(float now) => Active && Authoritative && playing &&
            now >= receivedAt && now - receivedAt <= MaximumPredictionSeconds;

        public float Position(float now)
        {
            float current = position + (playing && Authoritative ? Mathf.Clamp(now - receivedAt, 0f, MaximumPredictionSeconds) : 0f);
            if (playing) current += correction * (1f - Mathf.SmoothStep(0f, 1f, Mathf.Clamp01((now - receivedAt) / .25f)));
            return duration > 0 ? Mathf.Min(current, duration) : current;
        }

        public bool MatchesEnvelope(float[] envelope, int frameRate)
        {
            if (!Active || Envelope == null || envelope == null || FrameRate != frameRate || envelope.Length != Envelope.Length) return false;
            for (int i = 0; i < envelope.Length; i++)
                if (float.IsNaN(envelope[i]) || float.IsInfinity(envelope[i]) || envelope[i] < 0f || envelope[i] > 1f ||
                    Mathf.Abs(envelope[i] - Envelope[i]) > .000001f) return false;
            return true;
        }

        public void Reset(bool newOwner = false)
        {
            RetireCurrent();
            if (newOwner) generationWatermarks.Clear();
        }

        private void RetireCurrent()
        {
            if (PlaybackId != null && retired.Add(PlaybackId))
            {
                retiredOrder.Enqueue(PlaybackId);
                while (retiredOrder.Count > 64) retired.Remove(retiredOrder.Dequeue());
            }
            PlaybackId = null;
            Envelope = null;
            FrameRate = 0;
            sequence = 0;
            playing = false;
            Paused = false;
            Authoritative = false;
            correction = 0f;
        }
    }
}
