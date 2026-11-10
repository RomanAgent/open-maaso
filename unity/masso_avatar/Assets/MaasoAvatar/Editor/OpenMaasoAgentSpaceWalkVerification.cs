#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Maaso.World;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>Actual receiver/AgentSpace/VRM PlayerLoop evidence. No UI or
    /// authored content can access this Editor-only verification entry.</summary>
    public static class OpenMaasoAgentSpaceWalkVerification
    {
        private const string Session = "OpenMaaso.VerifyAgentSpaceWalk";
        private static string output, stage;
        private static double started;
        private static double playStarted;
        private static int frames, lastFrame, renderCount;
        private static float movingStarted, settledAt;
        private static UnityAvatarCommandReceiver receiver;
        private static Animator animator;
        private static AgentSpaceController space;
        private static Vector3 home, movingRoot;
        private static Vector3 lastRoot, lastLeftFoot, lastRightFoot;
        private static Quaternion lastRotation;
        private static float lastTime, lastPhase;
        private static bool havePrevious;
        private static readonly Queue<Result> replies = new();
        private static readonly List<string> receipts = new();
        private static readonly List<Sample> samples = new();
        private static readonly List<float> stanceSpeeds = new();

        [Serializable] private sealed class Envelope { public string method, json; }
        [Serializable] private sealed class MoveRequest { public string requestId, sessionId; public float x, y; }
        [Serializable] private sealed class Result { public string method, requestId, sessionId, code; public bool ok; }
        [Serializable] private sealed class Sample
        {
            public int frame; public float elapsed, phase, speed, stride;
            public Vector3 root, hipsLocal, leftFoot, rightFoot;
            public bool walking;
        }
        [Serializable] private sealed class Receipt
        {
            public string kind = "Real receiver AgentSpace move, Animator, VRM and GPU rendering; not a phone recording";
            public string[] commandReceipts; public Sample[] frames;
            public float rootDistance, maximumStanceWorldSpeed;
            public bool stoppedInIdle, cancellationReturnedHome;
        }

        public static void Begin()
        {
            if (Application.isBatchMode) throw new InvalidOperationException("Use a real Game View, without -batchmode/-nographics.");
            output = Environment.GetEnvironmentVariable("OPEN_MAASO_WALK_CAPTURE");
            if (string.IsNullOrWhiteSpace(output)) throw new InvalidOperationException("Set OPEN_MAASO_WALK_CAPTURE.");
            EditorSceneManager.OpenScene(MaasoDefaultAvatarSceneBuilder.ScenePath, OpenSceneMode.Single);
            Type viewType = AppDomain.CurrentDomain.GetAssemblies().Select(a => a.GetType("UnityEditor.GameView")).First(t => t != null);
            var view = EditorWindow.GetWindow(viewType); view.Show(); view.Focus();
            SessionState.SetString(Session + ".Output", Path.GetFullPath(output));
            SessionState.SetBool(Session, true);
            EditorApplication.EnterPlaymode();
        }

        [InitializeOnLoadMethod]
        private static void Resume()
        {
            if (!SessionState.GetBool(Session, false)) return;
            output = SessionState.GetString(Session + ".Output", "");
            started = EditorApplication.timeSinceStartup;
            playStarted = -1;
            frames = renderCount = 0; lastFrame = -1; stage = "boot"; havePrevious = false;
            replies.Clear(); receipts.Clear(); samples.Clear(); stanceSpeeds.Clear();
            Application.logMessageReceived += Read;
            EditorApplication.update += Tick;
        }

        private static void Read(string message, string stack, LogType type)
        {
            const string prefix = "[UnityAvatar] command result ";
            if (!message.StartsWith(prefix, StringComparison.Ordinal)) return;
            var result = JsonUtility.FromJson<Result>(message.Substring(prefix.Length));
            if (result?.requestId?.StartsWith("walk-proof-", StringComparison.Ordinal) != true) return;
            receipts.Add(message.Substring(prefix.Length)); replies.Enqueue(result);
        }

        private static void Tick()
        {
            try
            {
                if (EditorApplication.timeSinceStartup - started > 240) throw new TimeoutException("AgentSpace verification Editor startup did not complete.");
                if (!EditorApplication.isPlaying) return;
                if (playStarted < 0) playStarted = EditorApplication.timeSinceStartup;
                if (EditorApplication.timeSinceStartup - playStarted > 90) throw new TimeoutException("AgentSpace walk proof did not complete.");
                if (Time.frameCount == lastFrame) return;
                lastFrame = Time.frameCount; frames++;
                if (frames == 10)
                {
                    receiver = Object.FindAnyObjectByType<UnityAvatarCommandReceiver>();
                    Send("loadAvatar", "{\"requestId\":\"walk-proof-load\",\"modelUrl\":\"unity://masso/avatar_agent\"}");
                    Send("setFraming", "{\"mode\":\"hero_full_body\"}");
                    Send("setLocalAvatarVisible", "{\"visible\":true}");
                }
                if (frames < 90) return;
                while (replies.Count > 0)
                {
                    Result reply = replies.Dequeue();
                    if (!reply.ok) throw new InvalidOperationException(reply.requestId + ": " + reply.code);
                    if (reply.requestId == "walk-proof-enter") stage = "ready";
                    if (reply.requestId == "walk-proof-cancel") stage = "cancelled";
                }
                if (stage == "boot")
                {
                    Directory.CreateDirectory(output);
                    home = receiver.ActiveAvatarRoot.position;
                    animator = receiver.ActiveAvatarRoot.GetComponentInChildren<Animator>();
                    Send("enterAgentSpace", "{\"requestId\":\"walk-proof-enter\",\"sessionId\":\"walk-proof-space\",\"animated\":true}");
                    stage = "entering";
                }
                if (stage == "ready")
                {
                    space = Object.FindAnyObjectByType<AgentSpaceController>();
                    if (space == null || !space.IsActive) throw new InvalidOperationException("The original AgentSpace did not become active.");
                    movingRoot = receiver.ActiveAvatarRoot.position;
                    Move("walk-proof-move", 2.2f);
                    stage = "moving"; movingStarted = Time.realtimeSinceStartup;
                }
                if (stage == "moving")
                {
                    Record();
                    if (samples.Count(s => s.walking) >= (renderCount + 1) * 4 && renderCount < 4)
                    {
                        Render(Camera.main, Path.Combine(output, renderCount.ToString("00") + "-world.png"));
                        RenderActor(renderCount.ToString("00") + "-front.png", Vector3.forward);
                        RenderActor(renderCount.ToString("00") + "-side.png", Vector3.right);
                        renderCount++;
                    }
                    var owner = Object.FindAnyObjectByType<WorldOwnerAvatarLease>();
                    if (Time.realtimeSinceStartup - movingStarted > .2f && owner != null && !owner.IsMoving)
                    { stage = "settling"; settledAt = Time.realtimeSinceStartup; }
                }
                if (stage == "settling" && Time.realtimeSinceStartup - settledAt > .4f)
                {
                    if (!animator.GetCurrentAnimatorStateInfo(0).IsName("Idle")) throw new InvalidOperationException("Native route completion did not return to Idle.");
                    if (Vector3.Distance(movingRoot, receiver.ActiveAvatarRoot.position) < 1f) throw new InvalidOperationException("The native owner did not actually move.");
                    if (renderCount < 2) throw new InvalidOperationException("The actual walk did not expose enough rendered stride frames.");
                    Move("walk-proof-second-move", 1f); stage = "cancelling"; settledAt = Time.realtimeSinceStartup;
                }
                if (stage == "cancelling" && Time.realtimeSinceStartup - settledAt > .20f)
                {
                    Send("leaveAgentSpace", "{\"requestId\":\"walk-proof-cancel\",\"sessionId\":\"walk-proof-space\",\"animated\":false}");
                    stage = "leaving"; settledAt = Time.realtimeSinceStartup;
                }
                if (stage == "cancelled" && Time.realtimeSinceStartup - settledAt > .4f)
                {
                    if (!animator.GetCurrentAnimatorStateInfo(0).IsName("Idle") || animator.applyRootMotion)
                        throw new InvalidOperationException("Cancellation did not release walking to the verified idle/root owner.");
                    if (Vector3.Distance(home, receiver.ActiveAvatarRoot.position) > .03f) throw new InvalidOperationException("Cancellation did not restore the Home owner.");
                    if (stanceSpeeds.Count < 3) throw new InvalidOperationException("No actual support-foot world samples were collected.");
                    float maximum = stanceSpeeds.Max();
                    if (maximum > .45f) throw new InvalidOperationException("Support feet slide despite native gait calibration: " + maximum);
                    File.WriteAllText(Path.Combine(output, "walk-receipt.json"), JsonUtility.ToJson(new Receipt
                    {
                        commandReceipts = receipts.ToArray(), frames = samples.ToArray(),
                        rootDistance = Vector3.Distance(movingRoot, samples[^1].root), maximumStanceWorldSpeed = maximum,
                        stoppedInIdle = true, cancellationReturnedHome = true,
                    }, true));
                    Complete(0);
                }
            }
            catch (Exception error) { Debug.LogException(error); Complete(1); }
        }

        private static void Move(string request, float distance)
        {
            var room = PersistentWorldMapController.EnsureRuntimeMap();
            var navigation = CoastalPrivateWorldContract.FindNavigation(room);
            var root = receiver.ActiveAvatarRoot;
            var camera = Camera.main;
            foreach (Vector3 direction in new[] { Vector3.forward, Vector3.back, Vector3.right, Vector3.left })
            {
                Vector3 goal = root.position + direction * distance; goal.y = PersistentWorldMapController.GroundY;
                if (!navigation.TryBuildRoute(root.position, goal, navigation.RouteNodes, out _)) continue;
                Vector3 point = camera.WorldToViewportPoint(goal);
                if (point.z <= 0 || point.x < .03f || point.x > .97f || point.y < .03f || point.y > .97f) continue;
                Send("requestAgentSpaceMoveAtScreenPoint", JsonUtility.ToJson(new MoveRequest
                { requestId = request, sessionId = "walk-proof-space", x = point.x, y = 1f - point.y }));
                return;
            }
            throw new InvalidOperationException("The original room has no visible verified floor route for this probe.");
        }

        private static void Record()
        {
            Transform root = receiver.ActiveAvatarRoot;
            var state = animator.IsInTransition(0) ? animator.GetNextAnimatorStateInfo(0) : animator.GetCurrentAnimatorStateInfo(0);
            bool walking = state.IsName("standard_walk");
            Vector3 left = animator.GetBoneTransform(HumanBodyBones.LeftFoot).position;
            Vector3 right = animator.GetBoneTransform(HumanBodyBones.RightFoot).position;
            float phase = Mathf.Repeat(state.normalizedTime, 1f), now = Time.realtimeSinceStartup;
            samples.Add(new Sample { frame = Time.frameCount, elapsed = now - movingStarted, phase = phase,
                speed = animator.GetFloat("WorldWalkSpeed"), stride = animator.GetFloat("WorldWalkStride"),
                root = root.position, hipsLocal = root.InverseTransformPoint(animator.GetBoneTransform(HumanBodyBones.Hips).position),
                leftFoot = left, rightFoot = right, walking = walking });
            if (havePrevious && walking && !animator.IsInTransition(0) && now - lastTime < .12f && now - movingStarted > .2f &&
                Vector3.Distance(root.position, lastRoot) > .001f && Mathf.Abs(phase - lastPhase) < .3f &&
                Quaternion.Angle(root.rotation, lastRotation) < .1f)
            {
                float dt = now - lastTime;
                if (phase > .08f && phase < .42f && lastPhase > .05f && lastPhase < .45f)
                    stanceSpeeds.Add(Vector3.ProjectOnPlane(left - lastLeftFoot, Vector3.up).magnitude / dt);
                if (phase > .58f && phase < .92f && lastPhase > .55f && lastPhase < .95f)
                    stanceSpeeds.Add(Vector3.ProjectOnPlane(right - lastRightFoot, Vector3.up).magnitude / dt);
            }
            havePrevious = true; lastRoot = root.position; lastRotation = root.rotation;
            lastLeftFoot = left; lastRightFoot = right; lastTime = now; lastPhase = phase;
        }

        private static void RenderActor(string file, Vector3 direction)
        {
            Renderer[] renderers = receiver.ActiveAvatarRoot.GetComponentsInChildren<Renderer>();
            Bounds bounds = renderers[0].bounds; foreach (var renderer in renderers) bounds.Encapsulate(renderer.bounds);
            GameObject probe = new GameObject("WalkVerificationCamera");
            var camera = probe.AddComponent<Camera>(); camera.clearFlags = CameraClearFlags.SolidColor; camera.backgroundColor = Color.white;
            camera.fieldOfView = 30f; camera.aspect = 720f / 1280f; camera.cullingMask = 1 << 31;
            camera.transform.position = bounds.center + direction * (bounds.size.y / (2f * Mathf.Tan(15f * Mathf.Deg2Rad)) * 1.12f);
            camera.transform.LookAt(bounds.center);
            int[] layers = renderers.Select(r => r.gameObject.layer).ToArray();
            try { foreach (var renderer in renderers) renderer.gameObject.layer = 31; Render(camera, Path.Combine(output, file)); }
            finally { for (int i = 0; i < renderers.Length; i++) renderers[i].gameObject.layer = layers[i]; Object.DestroyImmediate(probe); }
        }

        private static void Render(Camera camera, string path)
        {
            RenderTexture previous = camera.targetTexture, active = RenderTexture.active;
            var target = new RenderTexture(720, 1280, 24); var image = new Texture2D(720, 1280, TextureFormat.RGB24, false);
            try { target.Create(); camera.targetTexture = target; camera.Render(); RenderTexture.active = target;
                image.ReadPixels(new Rect(0, 0, 720, 1280), 0, 0); image.Apply(); File.WriteAllBytes(path, image.EncodeToPNG()); }
            finally { camera.targetTexture = previous; RenderTexture.active = active; target.Release(); Object.DestroyImmediate(target); Object.DestroyImmediate(image); }
        }
        private static void Send(string method, string json) => receiver.OnFlutterCommand(JsonUtility.ToJson(new Envelope { method = method, json = json }));
        private static void Complete(int code)
        {
            SessionState.SetBool(Session, false); EditorApplication.update -= Tick; Application.logMessageReceived -= Read;
            EditorApplication.Exit(code);
        }
    }
}
#endif
