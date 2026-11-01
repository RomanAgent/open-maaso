using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Maaso.Avatar
{
    [DisallowMultipleComponent]
    internal sealed class DesktopUnitySidecarBridge : MonoBehaviour
    {
        private static readonly HashSet<string> AvatarMethods = new(
            new[]
            {
                "prepareView", "loadAvatar",
                "setExpression", "setMouthOpen", "setGaze",
                "clearGaze", "startLipSync", "startVisemeTimeline", "stopLipSync", "playPrimitive",
                "playAnimationClip", "reactToScreenTap",
                "transitionPresence", "transitionLoginDoorway", "setPhoneInteraction", "setLocalAvatarVisible",
                "setBackgroundTaskWork",
                "setHandIkTarget", "setBodyPose", "playMotion", "playMotionSequence",
                "setFraming", "setViewportSafeArea", "setWorldTimeOfDay", "setWorldCamera",
                "enterAgentSpace", "leaveAgentSpace", "requestAgentSpaceMoveAtScreenPoint",
                "pause", "resume", "avatarArbiterCommand", "avatarArbiterReset",
            },
            StringComparer.Ordinal);
        public static bool SupportsAvatarMethod(string method) => method != null && AvatarMethods.Contains(method);

        // Pure wire validation is also compiled in the Editor so contract tests
        // exercise exactly the parser used by the macOS sidecar. Native startup
        // and socket lifecycle remain platform guarded below.
        private const int MaximumSequence = 0x7fffffff;
        private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);

        private static PortalCommand ParsePortalCommand(JObject payload)
        {
            string method = RequiredString(payload, "method", 32);
            int generation = RequiredInt(payload, "generation", 1, MaximumSequence);
            if (!IsAllowedPortalMethod(method))
            {
                throw new InvalidOperationException("Rejected sidecar portal command.");
            }
            if (string.Equals(method, "acquire", StringComparison.Ordinal))
            {
                JToken worldToken = payload["includeWorld"];
                if (worldToken != null && worldToken.Type != JTokenType.Boolean)
                    throw new InvalidOperationException("Rejected sidecar portal scene flag.");
                bool includeWorld = worldToken != null && worldToken.Value<bool>();
                if (includeWorld)
                    RequireExactProperties(payload, "method", "generation", "profile", "targetFps",
                        "includeWorld", "viewportWidth", "viewportHeight");
                else if (worldToken != null)
                    RequireExactProperties(payload, "method", "generation", "profile", "targetFps", "includeWorld");
                else
                    RequireExactProperties(payload, "method", "generation", "profile", "targetFps");
                int viewportWidth = includeWorld ? RequiredInt(payload, "viewportWidth", 64, 3840) : 0;
                int viewportHeight = includeWorld ? RequiredInt(payload, "viewportHeight", 64, 2160) : 0;
                string profile = RequiredString(payload, "profile", 32);
                int targetFps = RequiredInt(payload, "targetFps", 24, 60);
                if (!IsAllowedProfile(profile))
                {
                    throw new InvalidOperationException(
                        "Rejected sidecar portal profile.");
                }
                if (targetFps != 24 && targetFps != 30 && targetFps != 60)
                {
                    throw new InvalidOperationException(
                        "Rejected sidecar portal target FPS.");
                }
                return new PortalCommand(method, generation, profile, targetFps,
                    includeWorld, viewportWidth, viewportHeight);
            }
            RequireExactProperties(payload, "method", "generation");
            return new PortalCommand(method, generation, string.Empty, 0);
        }

        private static void RequireExactProperties(
            JObject value,
            params string[] expected)
        {
            var actual = new HashSet<string>(StringComparer.Ordinal);
            foreach (JProperty property in value.Properties())
            {
                actual.Add(property.Name);
            }
            if (!actual.SetEquals(expected))
            {
                throw new InvalidOperationException("JSON object shape is invalid.");
            }
        }

        private static string RequiredString(
            JObject value,
            string property,
            int maximumBytes)
        {
            JToken token = value[property];
            if (token == null || token.Type != JTokenType.String)
            {
                throw new InvalidOperationException(property + " must be a string.");
            }
            string result = token.Value<string>() ?? string.Empty;
            if (string.IsNullOrEmpty(result) ||
                StrictUtf8.GetByteCount(result) > maximumBytes)
            {
                throw new InvalidOperationException(property + " is out of bounds.");
            }
            return result;
        }

        private static int RequiredInt(
            JObject value,
            string property,
            int minimum,
            int maximum)
        {
            JToken token = value[property];
            if (token == null || token.Type != JTokenType.Integer)
            {
                throw new InvalidOperationException(property + " must be an integer.");
            }
            long result = token.Value<long>();
            if (result < minimum || result > maximum)
            {
                throw new InvalidOperationException(property + " is out of bounds.");
            }
            return (int)result;
        }

        private static bool IsAllowedPortalMethod(string value)
        {
            return string.Equals(value, "acquire", StringComparison.Ordinal) ||
                string.Equals(value, "suspend", StringComparison.Ordinal) ||
                string.Equals(value, "resume", StringComparison.Ordinal) ||
                string.Equals(value, "release", StringComparison.Ordinal);
        }

        private static bool IsAllowedProfile(string value)
        {
            return string.Equals(value, "desktopHigh", StringComparison.Ordinal) ||
                string.Equals(value, "compactHigh", StringComparison.Ordinal) ||
                string.Equals(value, "compactBalanced", StringComparison.Ordinal) ||
                string.Equals(value, "compactLow", StringComparison.Ordinal);
        }

        private readonly struct PortalCommand
        {
            internal PortalCommand(
                string method,
                int generation,
                string profile,
                int targetFps,
                bool includeWorld = false,
                int viewportWidth = 0,
                int viewportHeight = 0)
            {
                Method = method;
                Generation = generation;
                Profile = profile;
                TargetFps = targetFps;
                IncludeWorld = includeWorld;
                ViewportWidth = viewportWidth;
                ViewportHeight = viewportHeight;
            }

            internal string Method { get; }
            internal int Generation { get; }
            internal string Profile { get; }
            internal int TargetFps { get; }
            internal bool IncludeWorld { get; }
            internal int ViewportWidth { get; }
            internal int ViewportHeight { get; }
        }

        private const int MaximumPayloadStringBytes = 32 * 1024;
        private const int MaximumJsonDepth = 6;
        private readonly ConcurrentQueue<InboundCommand> inboundCommands = new();

        // The socket reader is the producer; Update is the sole consumer. Both
        // command kinds must keep their shared wire order: leaveWorld precedes
        // avatar capture, and releasing capture precedes joining a world.
        private void EnqueueInboundCommand(string type, JObject payload)
        {
            if (string.Equals(type, "command", StringComparison.Ordinal))
            {
                inboundCommands.Enqueue(new InboundCommand(ParsePortalCommand(payload)));
                return;
            }
            if (string.Equals(type, "avatarCommand", StringComparison.Ordinal))
            {
                inboundCommands.Enqueue(new InboundCommand(ParseAvatarCommand(payload)));
                return;
            }
            throw new InvalidOperationException("Unsupported sidecar command type.");
        }

        // Keep this production queue drain available to EditMode tests without
        // opening a socket, polling IOSurfaces or starting native presentation.
        private void DrainInboundCommands(
            Func<bool> isAvatarReceiverReady,
            Action<string, int> dispatchPortal,
            Action<string> dispatchAvatar)
        {
            while (inboundCommands.TryPeek(out InboundCommand next))
            {
                // The old avatar queue waited for the receiver. Preserve that
                // wait without allowing a later portal acquisition to overtake.
                if (!next.IsPortal && !isAvatarReceiverReady()) return;
                if (!inboundCommands.TryDequeue(out InboundCommand command)) continue;

                // Dequeue before dispatch, as before. Dispatch exceptions keep
                // their existing handler; do not requeue or retry side effects.
                if (command.IsPortal)
                {
                    PortalCommand portal = command.Portal;
                    dispatchPortal(new JObject
                    {
                        ["method"] = portal.Method,
                        ["profile"] = portal.Profile,
                        ["generation"] = portal.Generation,
                        ["targetFps"] = portal.TargetFps,
                        ["includeWorld"] = portal.IncludeWorld,
                        ["viewportWidth"] = portal.ViewportWidth,
                        ["viewportHeight"] = portal.ViewportHeight,
                    }.ToString(Formatting.None), portal.Generation);
                }
                else
                {
                    dispatchAvatar(new JObject
                    {
                        ["method"] = command.Avatar.Method,
                        ["json"] = command.Avatar.Json,
                    }.ToString(Formatting.None));
                }
            }
        }

        private readonly struct InboundCommand
        {
            internal InboundCommand(PortalCommand portal)
            {
                IsPortal = true;
                Portal = portal;
                Avatar = default;
            }

            internal InboundCommand(AvatarCommand avatar)
            {
                IsPortal = false;
                Portal = default;
                Avatar = avatar;
            }

            internal bool IsPortal { get; }
            internal PortalCommand Portal { get; }
            internal AvatarCommand Avatar { get; }
        }

        private static AvatarCommand ParseAvatarCommand(JObject payload)
        {
            RequireExactProperties(payload, "method", "json");
            string method = RequiredString(payload, "method", 64);
            string argumentsJson = RequiredString(
                payload,
                "json",
                MaximumPayloadStringBytes);
            if (!SupportsAvatarMethod(method))
            {
                throw new InvalidOperationException("Rejected Unity Avatar method.");
            }
            ParseObject(argumentsJson, MaximumPayloadStringBytes);
            return new AvatarCommand(method, argumentsJson);
        }

        private static JObject ParseObject(string json, int maximumBytes)
        {
            if (string.IsNullOrWhiteSpace(json) ||
                StrictUtf8.GetByteCount(json) > maximumBytes)
            {
                throw new InvalidOperationException("JSON payload size is invalid.");
            }
            JObject value = JObject.Parse(
                json,
                new JsonLoadSettings
                {
                    DuplicatePropertyNameHandling =
                        DuplicatePropertyNameHandling.Error,
                });
            if (!IsBoundedJson(value, 0))
            {
                throw new InvalidOperationException("JSON payload is not bounded.");
            }
            return value;
        }

        private static bool IsBoundedJson(JToken value, int depth)
        {
            if (value == null || depth > MaximumJsonDepth)
            {
                return false;
            }
            if (value is JObject objectValue)
            {
                int count = 0;
                foreach (JProperty property in objectValue.Properties())
                {
                    count += 1;
                    if (count > 512 || string.IsNullOrEmpty(property.Name) ||
                        StrictUtf8.GetByteCount(property.Name) > 256 ||
                        !IsBoundedJson(property.Value, depth + 1))
                    {
                        return false;
                    }
                }
                return true;
            }
            if (value is JArray arrayValue)
            {
                if (arrayValue.Count > 4096)
                {
                    return false;
                }
                foreach (JToken child in arrayValue)
                {
                    if (!IsBoundedJson(child, depth + 1))
                    {
                        return false;
                    }
                }
                return true;
            }
            if (value.Type == JTokenType.String)
            {
                return StrictUtf8.GetByteCount(value.Value<string>() ?? string.Empty) <=
                    MaximumPayloadStringBytes;
            }
            return value.Type == JTokenType.Integer ||
                value.Type == JTokenType.Float ||
                value.Type == JTokenType.Boolean ||
                value.Type == JTokenType.Null;
        }

        private readonly struct AvatarCommand
        {
            internal AvatarCommand(string method, string json)
            {
                Method = method;
                Json = json;
            }

            internal string Method { get; }
            internal string Json { get; }
        }

#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
        private const int ProtocolVersion = 1;
        private const int MaximumFrameBytes = 64 * 1024;
        private static DesktopUnitySidecarBridge instance;
        private static volatile bool receiverReportedReady;

        private readonly object sendLock = new();
        private readonly object callbackLock = new();
        private readonly Queue<OutboundMessage> pendingCallbacks = new();
        private Socket socket;
        private Thread socketThread;
        private string sessionToken;
        private string socketPath;
        private int outgoingSequence;
        private int incomingSequence = -1;
        private int avatarReadySent;
        private int hideWindowFramesRemaining = 240;
        private int expectedParentProcessId;
        private volatile bool helloSent;
        private bool closing;
#endif

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        private static void Bootstrap()
        {
#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
            string token = Environment.GetEnvironmentVariable(
                "MAASO_AVATAR_SESSION_TOKEN") ?? string.Empty;
            string endpoint = Environment.GetEnvironmentVariable(
                "MAASO_AVATAR_SOCKET_PATH") ?? string.Empty;
            string rawParentProcessId = Environment.GetEnvironmentVariable(
                "MAASO_AVATAR_PARENT_PID") ?? string.Empty;
            if (!IsValidSessionToken(token) ||
                string.IsNullOrWhiteSpace(endpoint) ||
                Encoding.UTF8.GetByteCount(endpoint) > 103 ||
                !int.TryParse(rawParentProcessId, out int parentProcessId) ||
                parentProcessId <= 1 || getppid() != parentProcessId ||
                instance != null)
            {
                return;
            }

            var bridgeObject = new GameObject("Maaso Desktop Unity Sidecar");
            instance = bridgeObject.AddComponent<DesktopUnitySidecarBridge>();
            instance.sessionToken = token;
            instance.socketPath = endpoint;
            instance.expectedParentProcessId = parentProcessId;
            Application.runInBackground = true;
            DontDestroyOnLoad(bridgeObject);
            instance.StartSocketThread();
#endif
        }

        internal static void ReportAvatarReady()
        {
#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
            receiverReportedReady = true;
            instance?.TrySendAvatarReady();
#endif
        }

        internal static void ReportAvatarCommandResult(string payload)
        {
#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
            instance?.SendValidatedPayload("avatarResult", payload);
#endif
        }

        internal static void ReportPortalEvent(string type, int generation)
        {
#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
            if (instance == null || generation <= 0 || !IsSafeEventName(type))
            {
                return;
            }
            instance.SendFrame(
                "event",
                new JObject
                {
                    ["name"] = type,
                    ["generation"] = generation,
                });
#endif
        }

#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
        private void StartSocketThread()
        {
            socketThread = new Thread(RunSocket)
            {
                IsBackground = true,
                Name = "Maaso Avatar Sidecar IPC",
            };
            socketThread.Start();
        }

        private void RunSocket()
        {
            try
            {
                socket = new Socket(
                    AddressFamily.Unix,
                    SocketType.Stream,
                    ProtocolType.Unspecified);
                socket.Connect(new UnixDomainSocketEndPoint(socketPath));
                SendFrame(
                    "hello",
                    new JObject
                    {
                        ["platform"] = "macos",
                        ["processId"] =
                            System.Diagnostics.Process.GetCurrentProcess().Id,
                    });
                lock (callbackLock)
                {
                    helloSent = true;
                    while (pendingCallbacks.Count > 0)
                    {
                        OutboundMessage message = pendingCallbacks.Dequeue();
                        SendFrame(message.Type, message.Payload);
                    }
                }
                TrySendAvatarReady();
                ReadFrames();
            }
            catch (Exception exception)
            {
                if (!closing)
                {
                    Debug.LogError(
                        "[DesktopUnitySidecar] IPC failed: " + exception.Message);
                }
            }
            finally
            {
                CloseSocket();
            }
        }

        private void TrySendAvatarReady()
        {
            Socket current = socket;
            if (!receiverReportedReady || !helloSent ||
                current == null || !current.Connected)
            {
                return;
            }
            if (Interlocked.CompareExchange(ref avatarReadySent, 1, 0) != 0)
            {
                return;
            }
            SendFrame(
                "ready",
                new JObject
                {
                    ["renderer"] = "unity",
                    ["commandTransport"] = "sidecar",
                });
        }

        private void ReadFrames()
        {
            var buffer = new byte[4096];
            var frame = new List<byte>(4096);
            while (!closing)
            {
                int count = socket.Receive(buffer);
                if (count <= 0)
                {
                    return;
                }
                for (int index = 0; index < count; index += 1)
                {
                    byte value = buffer[index];
                    if (value == (byte)'\r')
                    {
                        throw new InvalidOperationException(
                            "Carriage returns are forbidden in sidecar frames.");
                    }
                    if (value == (byte)'\n')
                    {
                        if (frame.Count == 0)
                        {
                            throw new InvalidOperationException(
                                "Empty sidecar frame received.");
                        }
                        HandleFrame(StrictUtf8.GetString(frame.ToArray()));
                        frame.Clear();
                        continue;
                    }
                    frame.Add(value);
                    if (frame.Count >= MaximumFrameBytes)
                    {
                        throw new InvalidOperationException(
                            "Sidecar frame exceeds 64 KiB.");
                    }
                }
            }
        }

        private void HandleFrame(string json)
        {
            JObject envelope = ParseObject(json, MaximumFrameBytes);
            RequireExactProperties(
                envelope,
                "version", "session", "sequence", "type", "payload");
            int version = RequiredInt(envelope, "version", 0, MaximumSequence);
            int sequence = RequiredInt(envelope, "sequence", 0, MaximumSequence);
            string session = RequiredString(envelope, "session", 128);
            string type = RequiredString(envelope, "type", 64);
            if (version != ProtocolVersion ||
                !string.Equals(session, sessionToken, StringComparison.Ordinal) ||
                sequence <= incomingSequence ||
                envelope["payload"] is not JObject payload)
            {
                throw new InvalidOperationException(
                    "Invalid or unauthenticated sidecar command.");
            }
            incomingSequence = sequence;

            EnqueueInboundCommand(type, payload);
        }


        private void Update()
        {
            if (expectedParentProcessId <= 1 ||
                getppid() != expectedParentProcessId)
            {
                Application.Quit();
                return;
            }

            if (hideWindowFramesRemaining > 0)
            {
                hideWindowFramesRemaining -= 1;
                MaasoDesktopAvatarPortalHidePlayerWindow();
            }

            UnityAvatarCommandReceiver receiver = null;
            DrainInboundCommands(
                () =>
                {
                    if (receiver == null)
                        receiver = FindFirstObjectByType<UnityAvatarCommandReceiver>();
                    return receiver != null;
                },
                (payload, generation) =>
                {
                    CompanionPortalCaptureController controller =
                        FindFirstObjectByType<CompanionPortalCaptureController>();
                    if (controller == null)
                    {
                        ReportPortalEvent("portalControllerMissing", generation);
                        return;
                    }
                    controller.OnAvatarPortalCommand(payload);
                },
                payload => receiver.OnFlutterCommand(payload));

            while (MaasoDesktopAvatarPortalPollSurface(
                out uint surfaceId,
                out int width,
                out int height,
                out int generation,
                out long frameSequence))
            {
                if (surfaceId == 0 || width <= 0 || height <= 0 ||
                    generation <= 0 || frameSequence < 0)
                {
                    continue;
                }
                SendFrame(
                    "surface",
                    new JObject
                    {
                        ["surfaceId"] = surfaceId,
                        ["width"] = width,
                        ["height"] = height,
                        ["generation"] = generation,
                        ["frameSequence"] = frameSequence,
                        ["pixelFormat"] = "bgra8Unorm_srgb",
                    });
            }
        }

        private void SendValidatedPayload(string type, string payload)
        {
            if (string.IsNullOrWhiteSpace(payload) ||
                StrictUtf8.GetByteCount(payload) > MaximumPayloadStringBytes)
            {
                return;
            }
            try
            {
                JObject parsed = ParseObject(payload, MaximumPayloadStringBytes);
                lock (callbackLock)
                {
                    if (!helloSent)
                    {
                        if (pendingCallbacks.Count < 64)
                        {
                            pendingCallbacks.Enqueue(new OutboundMessage(type, parsed));
                        }
                        return;
                    }
                    SendFrame(type, parsed);
                }
            }
            catch (Exception exception)
            {
                Debug.LogWarning(
                    "[DesktopUnitySidecar] Dropped invalid " + type +
                    " payload: " + exception.Message);
            }
        }

        private void SendFrame(string type, JObject payload)
        {
            Socket current = socket;
            if (closing || current == null || !current.Connected)
            {
                return;
            }
            int sequence = Interlocked.Increment(ref outgoingSequence) - 1;
            if (sequence < 0 || sequence > MaximumSequence)
            {
                throw new InvalidOperationException("Sidecar sequence exhausted.");
            }
            var envelope = new JObject
            {
                ["version"] = ProtocolVersion,
                ["session"] = sessionToken,
                ["sequence"] = sequence,
                ["type"] = type,
                ["payload"] = payload,
            };
            byte[] bytes = StrictUtf8.GetBytes(
                envelope.ToString(Formatting.None) + "\n");
            if (bytes.Length > MaximumFrameBytes)
            {
                throw new InvalidOperationException(
                    "Outgoing sidecar frame exceeds 64 KiB.");
            }
            lock (sendLock)
            {
                int offset = 0;
                while (offset < bytes.Length)
                {
                    int sent = current.Send(
                        bytes,
                        offset,
                        bytes.Length - offset,
                        SocketFlags.None);
                    if (sent <= 0)
                    {
                        throw new InvalidOperationException(
                            "Sidecar socket closed during write.");
                    }
                    offset += sent;
                }
            }
        }

        private void OnDestroy()
        {
            closing = true;
            CloseSocket();
            if (ReferenceEquals(instance, this))
            {
                instance = null;
            }
        }

        private void OnApplicationQuit()
        {
            closing = true;
            CloseSocket();
        }

        private void CloseSocket()
        {
            Socket current = socket;
            socket = null;
            if (current == null)
            {
                return;
            }
            try
            {
                current.Shutdown(SocketShutdown.Both);
            }
            catch (SocketException)
            {
            }
            current.Close();
        }




        private static bool IsValidSessionToken(string value)
        {
            if (value == null || value.Length < 32 || value.Length > 128)
            {
                return false;
            }
            foreach (char character in value)
            {
                bool allowed =
                    (character >= 'a' && character <= 'z') ||
                    (character >= 'A' && character <= 'Z') ||
                    (character >= '0' && character <= '9') ||
                    character == '_' || character == '-';
                if (!allowed)
                {
                    return false;
                }
            }
            return true;
        }

        private static bool IsSafeEventName(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length > 64)
            {
                return false;
            }
            foreach (char character in value)
            {
                if (!char.IsLetterOrDigit(character))
                {
                    return false;
                }
            }
            return true;
        }

        [DllImport(
            "MaasoDesktopAvatarPortalBridge",
            EntryPoint = "MaasoDesktopAvatarPortalPollSurface")]
        [return: MarshalAs(UnmanagedType.I1)]
        private static extern bool MaasoDesktopAvatarPortalPollSurface(
            out uint surfaceId,
            out int width,
            out int height,
            out int generation,
            out long frameSequence);

        [DllImport(
            "MaasoDesktopAvatarPortalBridge",
            EntryPoint = "MaasoDesktopAvatarPortalHidePlayerWindow")]
        private static extern void MaasoDesktopAvatarPortalHidePlayerWindow();

        [DllImport("libc")]
        private static extern int getppid();


        private readonly struct OutboundMessage
        {
            internal OutboundMessage(string type, JObject payload)
            {
                Type = type;
                Payload = payload;
            }

            internal string Type { get; }
            internal JObject Payload { get; }
        }
#endif
    }
}
