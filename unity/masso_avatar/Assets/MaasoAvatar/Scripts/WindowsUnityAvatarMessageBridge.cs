using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Maaso.Avatar
{
    [DisallowMultipleComponent]
    internal sealed class WindowsUnityAvatarMessageBridge : MonoBehaviour
    {
#if UNITY_STANDALONE_WIN && !UNITY_EDITOR
        private const string SessionArgument = "-maasoAvatarSession";
        private const string HostWindowArgument = "-maasoAvatarHostHWND";
        private const uint WmCopyData = 0x004A;
        private const uint WmNcDestroy = 0x0082;
        private const int GwlWndProc = -4;
        private const long CommandMagic = 0x4d415643;
        private const long CallbackMagic = 0x4d415652;
        private const int ProtocolVersion = 1;
        private const int HeaderBytes = 16;
        private const int MaximumJsonBytes = 32 * 1024;
        private const int MaximumMethodBytes = 64;
        private const string DesktopPetPresentationMethod =
            "desktopPet.configurePresentation";

        private static readonly UTF8Encoding StrictUtf8 =
            new UTF8Encoding(false, true);
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

        private static WindowsUnityAvatarMessageBridge instance;
        private static bool receiverReportedReady;

        private readonly ConcurrentQueue<string> commands = new();
        private string sessionToken;
        private IntPtr hostWindow;
        private IntPtr playerWindow;
        private IntPtr previousWindowProcedure;
        private IntPtr installedWindowProcedure;
        private WindowProcedure windowProcedure;
        private int nextHookFrame;
        private bool readySent;
        private bool shuttingDown;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        private static void Bootstrap()
        {
            if (instance != null)
            {
                return;
            }
            string[] arguments = Environment.GetCommandLineArgs();
            string token = ArgumentValue(arguments, SessionArgument);
            string rawHostWindow = ArgumentValue(arguments, HostWindowArgument);
            if (!IsValidToken(token) ||
                !ulong.TryParse(rawHostWindow, out ulong hostValue) ||
                hostValue == 0)
            {
                return;
            }

            var host = new GameObject("Maaso Windows Unity Avatar IPC");
            instance = host.AddComponent<WindowsUnityAvatarMessageBridge>();
            instance.sessionToken = token;
            instance.hostWindow = new IntPtr(unchecked((long)hostValue));
            Application.runInBackground = true;
            DontDestroyOnLoad(host);
        }

        internal static void ReportAvatarReady()
        {
            receiverReportedReady = true;
            instance?.TrySendReady();
        }

        internal static void ReportAvatarCommandResult(string payload)
        {
            instance?.SendCallback("commandResult", payload ?? string.Empty);
        }

        private void Update()
        {
            if (shuttingDown)
            {
                return;
            }
            if (playerWindow != IntPtr.Zero && !IsWindow(playerWindow))
            {
                ClearWindowHookState(resetReady: true);
            }
            if (playerWindow == IntPtr.Zero && Time.frameCount >= nextHookFrame)
            {
                nextHookFrame = Time.frameCount + 15;
                TryInstallWindowProcedure();
            }
            TrySendReady();

            if (commands.IsEmpty)
            {
                return;
            }
            UnityAvatarCommandReceiver receiver = null;
            while (commands.TryDequeue(out string payload))
            {
                if (TryHandleDesktopPetPresentation(payload))
                {
                    continue;
                }
                receiver ??= FindAnyObjectByType<UnityAvatarCommandReceiver>();
                if (receiver == null)
                {
                    commands.Enqueue(payload);
                    return;
                }
                receiver.OnFlutterCommand(payload);
            }
        }

        private static bool TryHandleDesktopPetPresentation(string payload)
        {
            try
            {
                JObject envelope = JObject.Parse(payload);
                if (!string.Equals(
                    envelope.Value<string>("method"),
                    DesktopPetPresentationMethod,
                    StringComparison.Ordinal))
                {
                    return false;
                }
                JObject configuration = JObject.Parse(
                    envelope.Value<string>("json") ?? string.Empty);
                if (configuration.Count != 2 ||
                    configuration["quality"]?.Type != JTokenType.String ||
                    configuration["targetFps"]?.Type != JTokenType.Integer)
                {
                    return true;
                }
                WindowsDesktopPetPresentationController controller =
                    FindAnyObjectByType<WindowsDesktopPetPresentationController>();
                controller?.ApplyPresentationConfig(
                    configuration.Value<string>("quality"),
                    configuration.Value<int>("targetFps"));
                return true;
            }
            catch (Exception)
            {
                return false;
            }
        }

        private void TryInstallWindowProcedure()
        {
            int processId = Process.GetCurrentProcess().Id;
            IntPtr candidate = Process.GetCurrentProcess().MainWindowHandle;
            if (candidate == IntPtr.Zero)
            {
                EnumChildWindows(
                    GetDesktopWindow(),
                    (window, _) =>
                    {
                        GetWindowThreadProcessId(window, out uint windowProcessId);
                        if (windowProcessId != (uint)processId)
                        {
                            return true;
                        }
                        candidate = window;
                        return false;
                    },
                    IntPtr.Zero);
            }
            if (candidate == IntPtr.Zero)
            {
                return;
            }

            windowProcedure = HandleWindowMessage;
            installedWindowProcedure =
                Marshal.GetFunctionPointerForDelegate(windowProcedure);
            SetLastErrorCode(0);
            IntPtr previous = SetWindowLongPtr(
                candidate,
                GwlWndProc,
                installedWindowProcedure);
            if (previous == IntPtr.Zero)
            {
                installedWindowProcedure = IntPtr.Zero;
                windowProcedure = null;
                return;
            }
            playerWindow = candidate;
            previousWindowProcedure = previous;
        }

        private IntPtr HandleWindowMessage(
            IntPtr window,
            uint message,
            IntPtr wParam,
            IntPtr lParam)
        {
            WindowProcedure activeProcedure = windowProcedure;
            if (!shuttingDown &&
                message == WmCopyData &&
                wParam == hostWindow &&
                TryReceiveCommand(lParam))
            {
                return new IntPtr(1);
            }
            IntPtr previous = previousWindowProcedure;
            IntPtr result = previous != IntPtr.Zero
                ? CallWindowProcW(previous, window, message, wParam, lParam)
                : DefWindowProcW(window, message, wParam, lParam);
            if (message == WmNcDestroy && window == playerWindow)
            {
                ClearWindowHookState(resetReady: true);
                if (shuttingDown && ReferenceEquals(instance, this))
                {
                    instance = null;
                }
            }
            GC.KeepAlive(activeProcedure);
            return result;
        }

        private bool TryReceiveCommand(IntPtr rawCopyData)
        {
            if (rawCopyData == IntPtr.Zero)
            {
                return false;
            }
            CopyData copyData = Marshal.PtrToStructure<CopyData>(rawCopyData);
            if (copyData.DataId.ToInt64() != CommandMagic ||
                copyData.Data == IntPtr.Zero ||
                copyData.Size < HeaderBytes ||
                copyData.Size > HeaderBytes + 128 + MaximumMethodBytes + MaximumJsonBytes)
            {
                return false;
            }
            var bytes = new byte[copyData.Size];
            Marshal.Copy(copyData.Data, bytes, 0, bytes.Length);
            int version = ReadInt32(bytes, 0);
            int tokenBytes = ReadInt32(bytes, 4);
            int methodBytes = ReadInt32(bytes, 8);
            int jsonBytes = ReadInt32(bytes, 12);
            if (version != ProtocolVersion ||
                tokenBytes != StrictUtf8.GetByteCount(sessionToken) ||
                methodBytes <= 0 || methodBytes > MaximumMethodBytes ||
                jsonBytes <= 0 || jsonBytes > MaximumJsonBytes ||
                HeaderBytes + tokenBytes + methodBytes + jsonBytes != bytes.Length)
            {
                return true;
            }
            try
            {
                int offset = HeaderBytes;
                string token = StrictUtf8.GetString(bytes, offset, tokenBytes);
                offset += tokenBytes;
                string method = StrictUtf8.GetString(bytes, offset, methodBytes);
                offset += methodBytes;
                string json = StrictUtf8.GetString(bytes, offset, jsonBytes);
                if (!string.Equals(token, sessionToken, StringComparison.Ordinal) ||
                    (!AvatarMethods.Contains(method) &&
                     !string.Equals(
                         method,
                         DesktopPetPresentationMethod,
                         StringComparison.Ordinal)) ||
                    JObject.Parse(json) == null)
                {
                    return true;
                }
                commands.Enqueue(
                    new JObject
                    {
                        ["method"] = method,
                        ["json"] = json,
                    }.ToString(Formatting.None));
            }
            catch (Exception)
            {
                // The authenticated sender still has to satisfy strict UTF-8
                // and JSON bounds before a command reaches Unity gameplay code.
            }
            return true;
        }

        private void TrySendReady()
        {
            if (readySent ||
                !receiverReportedReady ||
                playerWindow == IntPtr.Zero ||
                installedWindowProcedure == IntPtr.Zero ||
                !IsWindow(playerWindow))
            {
                return;
            }
            readySent = SendCallback("ready", string.Empty);
        }

        private bool SendCallback(string type, string payload)
        {
            if (hostWindow == IntPtr.Zero ||
                string.IsNullOrEmpty(type) ||
                type.Length > MaximumMethodBytes)
            {
                return false;
            }
            payload ??= string.Empty;
            byte[] token = StrictUtf8.GetBytes(sessionToken);
            byte[] method = StrictUtf8.GetBytes(type);
            byte[] json = StrictUtf8.GetBytes(payload);
            if (json.Length > MaximumJsonBytes)
            {
                return false;
            }
            var packet = new byte[HeaderBytes + token.Length + method.Length + json.Length];
            WriteInt32(packet, 0, ProtocolVersion);
            WriteInt32(packet, 4, token.Length);
            WriteInt32(packet, 8, method.Length);
            WriteInt32(packet, 12, json.Length);
            Buffer.BlockCopy(token, 0, packet, HeaderBytes, token.Length);
            Buffer.BlockCopy(method, 0, packet, HeaderBytes + token.Length, method.Length);
            Buffer.BlockCopy(
                json,
                0,
                packet,
                HeaderBytes + token.Length + method.Length,
                json.Length);

            IntPtr data = Marshal.AllocHGlobal(packet.Length);
            try
            {
                Marshal.Copy(packet, 0, data, packet.Length);
                var copyData = new CopyData
                {
                    DataId = new IntPtr(CallbackMagic),
                    Size = packet.Length,
                    Data = data,
                };
                IntPtr sourceWindow = playerWindow;
                IntPtr sent = SendMessageTimeout(
                    hostWindow,
                    WmCopyData,
                    sourceWindow,
                    ref copyData,
                    0x0002,
                    100,
                    out IntPtr receiverResult);
                return sent != IntPtr.Zero && receiverResult != IntPtr.Zero;
            }
            finally
            {
                Marshal.FreeHGlobal(data);
            }
        }

        private void OnDestroy()
        {
            shuttingDown = true;
            bool canReleaseProcedure = true;
            if (playerWindow != IntPtr.Zero && IsWindow(playerWindow))
            {
                IntPtr current = GetWindowLongPtr(playerWindow, GwlWndProc);
                if (previousWindowProcedure == IntPtr.Zero ||
                    installedWindowProcedure == IntPtr.Zero ||
                    current != installedWindowProcedure)
                {
                    canReleaseProcedure = false;
                }
                else
                {
                    SetLastErrorCode(0);
                    IntPtr replaced = SetWindowLongPtr(
                        playerWindow,
                        GwlWndProc,
                        previousWindowProcedure);
                    canReleaseProcedure =
                        replaced != IntPtr.Zero || Marshal.GetLastWin32Error() == 0;
                }
            }
            if (canReleaseProcedure)
            {
                ClearWindowHookState(resetReady: false);
                if (ReferenceEquals(instance, this))
                {
                    instance = null;
                }
            }
        }

        private void ClearWindowHookState(bool resetReady)
        {
            playerWindow = IntPtr.Zero;
            previousWindowProcedure = IntPtr.Zero;
            installedWindowProcedure = IntPtr.Zero;
            windowProcedure = null;
            nextHookFrame = 0;
            if (resetReady)
            {
                readySent = false;
            }
        }

        private static string ArgumentValue(string[] arguments, string key)
        {
            for (int index = 0; index + 1 < arguments.Length; index += 1)
            {
                if (string.Equals(arguments[index], key, StringComparison.Ordinal))
                {
                    return arguments[index + 1] ?? string.Empty;
                }
            }
            return string.Empty;
        }

        private static bool IsValidToken(string value)
        {
            if (value == null || value.Length != 64)
            {
                return false;
            }
            foreach (char character in value)
            {
                bool valid =
                    (character >= 'a' && character <= 'f') ||
                    (character >= '0' && character <= '9');
                if (!valid)
                {
                    return false;
                }
            }
            return true;
        }

        private static int ReadInt32(byte[] bytes, int offset)
        {
            return bytes[offset] |
                (bytes[offset + 1] << 8) |
                (bytes[offset + 2] << 16) |
                (bytes[offset + 3] << 24);
        }

        private static void WriteInt32(byte[] bytes, int offset, int value)
        {
            bytes[offset] = (byte)value;
            bytes[offset + 1] = (byte)(value >> 8);
            bytes[offset + 2] = (byte)(value >> 16);
            bytes[offset + 3] = (byte)(value >> 24);
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CopyData
        {
            internal IntPtr DataId;
            internal int Size;
            internal IntPtr Data;
        }

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate IntPtr WindowProcedure(
            IntPtr window,
            uint message,
            IntPtr wParam,
            IntPtr lParam);

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate bool EnumWindowProcedure(IntPtr window, IntPtr parameter);

        [DllImport("user32.dll")]
        private static extern IntPtr GetDesktopWindow();

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumChildWindows(
            IntPtr parent,
            EnumWindowProcedure callback,
            IntPtr parameter);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(
            IntPtr window,
            out uint processId);

        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
        private static extern IntPtr SetWindowLongPtr(
            IntPtr window,
            int index,
            IntPtr value);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", ExactSpelling = true)]
        private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);

        [DllImport("user32.dll", EntryPoint = "CallWindowProcW", ExactSpelling = true)]
        private static extern IntPtr CallWindowProcW(
            IntPtr previous,
            IntPtr window,
            uint message,
            IntPtr wParam,
            IntPtr lParam);

        [DllImport("user32.dll", EntryPoint = "DefWindowProcW", ExactSpelling = true)]
        private static extern IntPtr DefWindowProcW(
            IntPtr window,
            uint message,
            IntPtr wParam,
            IntPtr lParam);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsWindow(IntPtr window);

        [DllImport("kernel32.dll", EntryPoint = "SetLastError", ExactSpelling = true)]
        private static extern void SetLastErrorCode(uint errorCode);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(
            IntPtr window,
            uint message,
            IntPtr wParam,
            ref CopyData lParam,
            uint flags,
            uint timeout,
            out IntPtr result);
#endif
    }
}
