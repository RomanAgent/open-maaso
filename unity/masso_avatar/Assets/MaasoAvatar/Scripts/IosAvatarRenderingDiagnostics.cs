using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>
    /// Small, local-only lifecycle receipt for iOS rendering investigations.
    /// Does not sample frames, capture textures, or alter rendering resources.
    /// </summary>
    public sealed class IosAvatarRenderingDiagnostics : MonoBehaviour
    {
#if UNITY_IOS && !UNITY_EDITOR
        private static IosAvatarRenderingDiagnostics instance;
        private bool started;
        private bool paused;
        private bool focused;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        private static void Bootstrap()
        {
            if (instance != null) return;
            GameObject host = null;
            try
            {
                host = new GameObject("Maaso iOS Rendering Diagnostics");
                host.hideFlags = HideFlags.HideInHierarchy | HideFlags.DontSave;
                DontDestroyOnLoad(host);
                instance = host.AddComponent<IosAvatarRenderingDiagnostics>();
            }
            catch (Exception)
            {
                if (host != null) Destroy(host);
            }
        }

        private IEnumerator Start()
        {
            // Begin on the next frame: no file IO or SystemInfo sampling in
            // first-frame startup, and no repeating update/capture loop.
            yield return null;
            focused = Application.isFocused;
            started = true;
            Record("startup");
        }

        private void OnApplicationPause(bool value)
        {
            if (paused == value) return;
            paused = value;
            if (started) Record(value ? "background" : "foreground");
        }

        private void OnApplicationFocus(bool value)
        {
            if (focused == value) return;
            focused = value;
            if (started) Record(value ? "focus_gained" : "focus_lost");
        }

        private void Record(string eventName)
        {
            try
            {
                var entry = IosAvatarRenderingDiagnosticLog.CreateEvent(
                    DateTime.UtcNow, eventName, Application.buildGUID,
                    Application.unityVersion, SystemInfo.graphicsDeviceType.ToString(),
                    SystemInfo.graphicsDeviceName, SystemInfo.renderingThreadingMode.ToString(),
                    Screen.width, Screen.height, ScalableBufferManager.widthScaleFactor,
                    ScalableBufferManager.heightScaleFactor, Application.isFocused);
                IosAvatarRenderingDiagnosticLog.TryAppendCache(Application.temporaryCachePath, entry);
            }
            catch (Exception)
            {
                // Diagnostics must never interrupt lifecycle/render recovery.
            }
        }

        private void OnDestroy()
        {
            if (instance == this) instance = null;
        }
#endif
    }

    /// <summary>
    /// Bounded payload/file helpers; callable in Editor tests without starting
    /// the iOS lifecycle component. No account, chat, device ID, or file paths
    /// enter the payload. Build policy is intentionally not an observed field.
    /// </summary>
    public static class IosAvatarRenderingDiagnosticLog
    {
        public const string RelativeCachePath = "maaso-render-diagnostics/unity-rendering-v1.json";
        public const int MaximumEvents = 12;
        public const int MaximumFileBytes = 32768;
        private static readonly Encoding Utf8 = new UTF8Encoding(false, true);

        [Serializable]
        public sealed class Event
        {
            public string utc;
            public string eventName;
            public string buildGuid;
            public string unityVersion;
            public string graphicsApi;
            public string graphicsDeviceName;
            public string observedRenderingThreadingMode;
            public int screenWidthPixels;
            public int screenHeightPixels;
            // These are dynamic-resolution buffer scales, NOT UIKit screen
            // points/pixels or a claim about the display's devicePixelRatio.
            public float dynamicResolutionWidthScale;
            public float dynamicResolutionHeightScale;
            public bool appFocused;
        }

        [Serializable]
        public sealed class Envelope
        {
            public int schemaVersion = 1;
            public Event[] events = Array.Empty<Event>();
        }

        public static Event CreateEvent(
            DateTime utc, string eventName, string buildGuid, string unityVersion,
            string graphicsApi, string graphicsDeviceName, string renderingThreadingMode,
            int width, int height, float widthScale, float heightScale, bool focused)
        {
            if (!AllowedEvent(eventName)) return null;
            return new Event
            {
                utc = utc.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture),
                eventName = eventName,
                buildGuid = Bounded(buildGuid, 64),
                unityVersion = Bounded(unityVersion, 32),
                graphicsApi = Bounded(graphicsApi, 64),
                graphicsDeviceName = Bounded(graphicsDeviceName, 128),
                observedRenderingThreadingMode = Bounded(renderingThreadingMode, 64),
                screenWidthPixels = Math.Max(0, Math.Min(width, 32768)),
                screenHeightPixels = Math.Max(0, Math.Min(height, 32768)),
                dynamicResolutionWidthScale = Scale(widthScale),
                dynamicResolutionHeightScale = Scale(heightScale),
                appFocused = focused,
            };
        }

        public static bool TryAppendCache(string cacheRoot, Event entry)
        {
            if (string.IsNullOrWhiteSpace(cacheRoot)) return false;
            string temporaryPath = null;
            try
            {
                Event normalized = Normalize(entry);
                if (normalized == null) return false;
                string path = Path.Combine(cacheRoot, RelativeCachePath);
                var previous = ReadBounded(path);
                var events = new List<Event>(MaximumEvents);
                foreach (Event candidate in previous.events ?? Array.Empty<Event>())
                {
                    Event valid = Normalize(candidate);
                    if (valid == null) continue;
                    if (events.Count == MaximumEvents - 1) events.RemoveAt(0);
                    events.Add(valid);
                }
                events.Add(normalized);
                string json = JsonUtility.ToJson(new Envelope { events = events.ToArray() });
                if (Utf8.GetByteCount(json) > MaximumFileBytes) return false;
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                temporaryPath = path + ".tmp";
                File.WriteAllText(temporaryPath, json, Utf8);
                if (File.Exists(path)) File.Replace(temporaryPath, path, null);
                else File.Move(temporaryPath, path);
                return true;
            }
            catch (Exception)
            {
                return false;
            }
            finally
            {
                try
                {
                    if (temporaryPath != null && File.Exists(temporaryPath)) File.Delete(temporaryPath);
                }
                catch (Exception) { }
            }
        }

        private static Envelope ReadBounded(string path)
        {
            try
            {
                if (!File.Exists(path) || new FileInfo(path).Length > MaximumFileBytes)
                    return new Envelope();
                // Bound the actual read as well as metadata: a concurrent
                // replacement/growing file cannot bypass the allocation cap.
                using var stream = File.OpenRead(path);
                var bytes = new byte[MaximumFileBytes + 1];
                int count = 0;
                while (count < bytes.Length)
                {
                    int read = stream.Read(bytes, count, bytes.Length - count);
                    if (read == 0) break;
                    count += read;
                }
                if (count > MaximumFileBytes) return new Envelope();
                Envelope value = JsonUtility.FromJson<Envelope>(Utf8.GetString(bytes, 0, count));
                return value != null && value.schemaVersion == 1 ? value : new Envelope();
            }
            catch (Exception)
            {
                return new Envelope();
            }
        }

        private static Event Normalize(Event entry)
        {
            if (entry == null || entry.utc == null || entry.utc.Length > 40 ||
                !DateTime.TryParse(entry.utc, CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind, out DateTime utc)) return null;
            return CreateEvent(utc, entry.eventName, entry.buildGuid, entry.unityVersion,
                entry.graphicsApi, entry.graphicsDeviceName, entry.observedRenderingThreadingMode,
                entry.screenWidthPixels, entry.screenHeightPixels,
                entry.dynamicResolutionWidthScale, entry.dynamicResolutionHeightScale, entry.appFocused);
        }

        private static bool AllowedEvent(string value) =>
            value == "startup" || value == "foreground" || value == "background" ||
            value == "focus_gained" || value == "focus_lost";

        private static float Scale(float value) =>
            float.IsNaN(value) || float.IsInfinity(value) ? 0f : Math.Max(0f, Math.Min(value, 4f));

        private static string Bounded(string value, int limit)
        {
            if (string.IsNullOrEmpty(value)) return string.Empty;
            var result = new StringBuilder(Math.Min(value.Length, limit));
            for (int i = 0; i < value.Length && result.Length < limit; i++)
            {
                char c = value[i];
                // Hardware/API names need no control or surrogate characters.
                result.Append(char.IsControl(c) || char.IsSurrogate(c) ? ' ' : c);
            }
            return result.ToString();
        }
    }
}
