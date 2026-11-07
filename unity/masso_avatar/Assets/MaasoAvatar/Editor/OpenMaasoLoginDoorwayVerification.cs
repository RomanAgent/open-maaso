#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Maaso.World;
using UnityEditor;
using UnityEngine;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>Actual receiver/Play Mode evidence, not a simulated Flutter UI.</summary>
    public static class OpenMaasoLoginDoorwayVerification
    {
        private const string Session = "OpenMaaso.VerifyLoginDoorway";
        private static readonly Queue<LoginDoorwayResult> pending = new();
        private static readonly List<string> receipts = new();
        private static double started;
        private static int frames, sequence;
        private static UnityAvatarCommandReceiver receiver;
        private static LoginDoorwayRig rig;
        private static Camera camera;
        private static RenderTexture target;
        private static string evidence, phase;
        private static float phaseStarted;
        private static bool halfway;
        private static Vector3 actorPosition;
        private static Quaternion actorRotation;

        public static void BeginCapture()
        {
            // The production receiver publishes camera receipts after an
            // actual frame. Unity Editor batchmode never resumes that yield.
            if (Application.isBatchMode)
                throw new InvalidOperationException("Run this visual bridge capture without -batchmode or -nographics.");
            MaasoDefaultAvatarSceneBuilder.RebuildScene();
            Type gameViewType = AppDomain.CurrentDomain.GetAssemblies()
                .Select(assembly => assembly.GetType("UnityEditor.GameView"))
                .First(type => type != null);
            EditorWindow view = EditorWindow.GetWindow(gameViewType);
            view.Show(); view.Focus();
            SessionState.SetBool(Session, true);
            EditorApplication.EnterPlaymode();
        }

        [InitializeOnLoadMethod]
        private static void Resume()
        {
            if (!SessionState.GetBool(Session, false)) return;
            started = EditorApplication.timeSinceStartup;
            frames = sequence = 0; phase = null; halfway = false;
            pending.Clear(); receipts.Clear();
            Application.logMessageReceived += ReadReceipt;
            EditorApplication.update += Tick;
        }

        private static void ReadReceipt(string message, string stack, LogType type)
        {
            const string prefix = "[UnityAvatar] command result ";
            if (!message.StartsWith(prefix, StringComparison.Ordinal)) return;
            var result = JsonUtility.FromJson<LoginDoorwayResult>(message.Substring(prefix.Length));
            if (result?.requestId?.StartsWith("public-door-", StringComparison.Ordinal) == true)
                pending.Enqueue(result);
        }

        private static void Tick()
        {
            try
            {
                if (EditorApplication.timeSinceStartup - started > 90)
                    throw new TimeoutException("The public doorway bridge did not finish all phases.");
                if (!EditorApplication.isPlaying) return;
                frames++;
                if (frames == 10)
                {
                    receiver = Object.FindAnyObjectByType<UnityAvatarCommandReceiver>();
                    Send("loadAvatar", "{\"requestId\":\"public-door-load\",\"modelUrl\":\"unity://masso/avatar_agent\"}");
                    Send("setFraming", "{\"mode\":\"hero_full_body\"}");
                    Send("setLocalAvatarVisible", "{\"visible\":true}");
                }
                if (frames < 90) return;
                if (phase == null)
                {
                    evidence = Environment.GetEnvironmentVariable("OPEN_MAASO_DOORWAY_EVIDENCE");
                    if (string.IsNullOrWhiteSpace(evidence)) throw new InvalidOperationException("Set OPEN_MAASO_DOORWAY_EVIDENCE.");
                    evidence = Path.GetFullPath(evidence); Directory.CreateDirectory(evidence);
                    rig = LoginDoorwayRig.Ensure(Object.FindAnyObjectByType<PersistentWorldMapController>());
                    if (rig == null) throw new InvalidOperationException("The scene did not expose its shared entry at runtime.");
                    camera = Camera.main;
                    target = new RenderTexture(900, 1950, 24, RenderTextureFormat.ARGB32) { antiAliasing = 4 };
                    target.Create(); camera.targetTexture = target; camera.aspect = 900f / 1950f;
                    camera.GetComponent<FrontFullBodyCamera>().FrameNow();
                    actorPosition = receiver.ActiveAvatarRoot.position;
                    actorRotation = receiver.ActiveAvatarRoot.rotation;
                    Phase("prepare", 0);
                }
                if (!halfway && phase == "open" && Time.realtimeSinceStartup - phaseStarted >= .325f)
                {
                    halfway = true; Save("02-opening.png");
                }
                if (!halfway && phase == "enter" && Time.realtimeSinceStartup - phaseStarted >= .6f)
                {
                    halfway = true; Save("04-entering.png");
                }
                while (pending.Count > 0)
                {
                    var result = pending.Dequeue();
                    if (result.method != "transitionLoginDoorway") continue;
                    receipts.Add(JsonUtility.ToJson(result));
                    if (!result.ok) throw new InvalidOperationException(result.phase + ":" + result.code);
                    switch (result.phase)
                    {
                        case "prepare":
                            Save("01-prepared.png");
                            string root = Path.GetFullPath(Path.Combine(Application.dataPath, "../../.."));
                            LoginDoorwayAssetBuilder.SaveFrame(camera, target, Path.Combine(root, "assets/brand/login_doorway.png"), poster: true);
                            Phase("open", 650); break;
                        case "open": Save("03-open.png"); Phase("enter", 1200); break;
                        case "enter": Save("05-entered.png"); Phase("frame", 300); break;
                        case "frame":
                            Save("06-avatar.png"); Finish(); return;
                    }
                }
            }
            catch (Exception error) { Debug.LogException(error); Stop(1); }
        }

        private static void Phase(string next, int duration)
        {
            phase = next; halfway = false; phaseStarted = Time.realtimeSinceStartup;
            Send("transitionLoginDoorway", JsonUtility.ToJson(new LoginDoorwayCommand
            {
                requestId = "public-door-" + next, transitionId = "public-doorway-capture",
                phase = next, durationMs = duration, sequence = ++sequence,
                expiresAtMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 60000,
            }));
        }

        private static void Send(string method, string json) =>
            receiver.OnFlutterCommand(JsonUtility.ToJson(new Envelope { method = method, json = json }));

        private static void Save(string name) => LoginDoorwayAssetBuilder.SaveFrame(camera, target, Path.Combine(evidence, name));

        private static void Finish()
        {
            if (receipts.Count != 4 || Vector3.Distance(actorPosition, receiver.ActiveAvatarRoot.position) > .005f ||
                Quaternion.Angle(actorRotation, receiver.ActiveAvatarRoot.rotation) > .2f ||
                Quaternion.Angle(rig.DoorHinge.localRotation, rig.SceneEntry.ClosedLocalRotation) > .01f)
                throw new InvalidOperationException("The doorway did not finish on the same existing actor with its shared door closed.");
            string root = Path.GetFullPath(Path.Combine(Application.dataPath, "../../.."));
            string poster = Path.Combine(root, "assets/brand/login_doorway.png");
            string provenance = JsonUtility.ToJson(new Provenance
            {
                unityVersion = Application.unityVersion,
                pngSha256 = Hash(File.ReadAllBytes(poster)),
                sceneDependencySha256 = Hash(Encoding.UTF8.GetBytes(string.Join("\n", AssetDatabase.GetDependencies(MaasoDefaultAvatarSceneBuilder.ScenePath, true).OrderBy(value => value, StringComparer.Ordinal)))),
                bridgeReceipts = receipts.ToArray(),
            }, true) + "\n";
            File.WriteAllText(Path.Combine(root, "assets/brand/login-doorway.provenance.json"), provenance);
            File.WriteAllText(Path.Combine(evidence, "bridge-receipts.json"), provenance);
            Debug.Log("[OpenMaasoDoorway] VERIFIED prepare/open650/enter1200/frame300 all acknowledged; same actor; closed shared door.");
            Stop(0);
        }

        private static string Hash(byte[] data)
        {
            using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(data)).Replace("-", "").ToLowerInvariant();
        }

        private static void Stop(int code)
        {
            SessionState.SetBool(Session, false);
            EditorApplication.update -= Tick; Application.logMessageReceived -= ReadReceipt;
            if (camera != null) camera.targetTexture = null;
            if (target != null) { target.Release(); Object.DestroyImmediate(target); }
            EditorApplication.Exit(code);
        }

        [Serializable] private sealed class Envelope { public string method, json; }
        [Serializable] private sealed class Provenance
        {
            public int schemaVersion = 1;
            public string owner = "Maaso project-owned primitive geometry; no licensed room/FBX/texture import";
            public string builder = "unity/masso_avatar/Assets/MaasoAvatar/Editor/OpenMaasoLoginDoorwayBuilder.cs";
            public string scene = MaasoDefaultAvatarSceneBuilder.ScenePath;
            public string captureMethod = "Maaso.Avatar.Editor.OpenMaasoLoginDoorwayVerification.BeginCapture";
            public string unityVersion, pngSha256, sceneDependencySha256;
            public string viewport = "Original prepare phase, upper 48%, 900x936 PNG";
            public string[] bridgeReceipts;
        }
    }
}
#endif
