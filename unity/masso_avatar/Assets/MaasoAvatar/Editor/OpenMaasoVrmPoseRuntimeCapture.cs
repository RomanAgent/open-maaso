#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

namespace Maaso.Avatar.Editor
{
    /// <summary>Pose evidence from the original receiver and actual skinned
    /// actor after normal PlayerLoop/VRM evaluation. The extra views isolate
    /// that unchanged actor only to make its limbs and fingers inspectable.</summary>
    public static class OpenMaasoVrmPoseRuntimeCapture
    {
        private const string Session = "OpenMaaso.CaptureCorrectedVrmPose";
        private static int frames, sampleIndex, settleFrames;
        private static double started;
        private static string output;
        private static UnityAvatarCommandReceiver receiver;
        private static Animator animator;
        private static Vector3 initialRoot;
        private static Quaternion initialRotation;
        private static readonly List<Sample> samples = new();
        [Serializable] private sealed class Envelope { public string method, json; }
        [Serializable] private sealed class Receipt { public string kind = "Unity PlayMode receiver and GPU skin rendering; not a phone screenshot"; public Sample[] samples; }
        [Serializable] private sealed class Sample
        {
            public float clipTime, leftElbowDegrees, rightElbowDegrees, leftKneeDegrees, rightKneeDegrees, handSeparation;
            public Vector3 rootPosition, leftHand, rightHand;
            public string[] images;
        }

        public static void Begin()
        {
            if (Application.isBatchMode) throw new InvalidOperationException("Run this capture with Game View, without -batchmode/-nographics.");
            output = Environment.GetEnvironmentVariable("OPEN_MAASO_POSE_CAPTURE");
            if (string.IsNullOrWhiteSpace(output)) throw new InvalidOperationException("Set OPEN_MAASO_POSE_CAPTURE.");
            EditorSceneManager.OpenScene(MaasoDefaultAvatarSceneBuilder.ScenePath, OpenSceneMode.Single);
            Type gameView = AppDomain.CurrentDomain.GetAssemblies().Select(assembly => assembly.GetType("UnityEditor.GameView")).First(type => type != null);
            var view = EditorWindow.GetWindow(gameView); view.Show(); view.Focus();
            SessionState.SetString(Session + ".Output", Path.GetFullPath(output));
            SessionState.SetBool(Session, true);
            EditorApplication.EnterPlaymode();
        }

        [InitializeOnLoadMethod]
        private static void Resume()
        {
            if (!SessionState.GetBool(Session, false)) return;
            output = SessionState.GetString(Session + ".Output", "");
            frames = sampleIndex = settleFrames = 0; samples.Clear(); started = EditorApplication.timeSinceStartup;
            EditorApplication.update += Tick;
        }

        private static void Tick()
        {
            try
            {
                if (EditorApplication.timeSinceStartup - started > 90) throw new TimeoutException("VRM pose capture did not complete.");
                if (!EditorApplication.isPlaying) return;
                frames++;
                if (frames == 10)
                {
                    receiver = UnityEngine.Object.FindAnyObjectByType<UnityAvatarCommandReceiver>();
                    Send("loadAvatar", "{\"requestId\":\"corrected-vrm-pose\",\"modelUrl\":\"unity://masso/avatar_agent\"}");
                    Send("setFraming", "{\"mode\":\"hero_full_body\"}");
                    Send("setLocalAvatarVisible", "{\"visible\":true}");
                }
                if (frames < 90) return;
                if (animator == null)
                {
                    animator = receiver.ActiveAvatarRoot.GetComponentInChildren<Animator>();
                    initialRoot = receiver.ActiveAvatarRoot.position; initialRotation = receiver.ActiveAvatarRoot.rotation;
                    animator.speed = 0;
                    Directory.CreateDirectory(output);
                }
                float clipTime = sampleIndex == 0 ? 0f : sampleIndex == 1 ? 2f : 3.99f;
                if (settleFrames++ == 0) animator.Play("Idle", 0, clipTime / 4f);
                if (settleFrames < 5) return;
                Sample sample = Inspect(clipTime);
                string prefix = sampleIndex.ToString("00");
                RenderWorld(prefix + "-world.png");
                RenderActor(prefix + "-front.png", Vector3.forward, false);
                RenderActor(prefix + "-side.png", Vector3.right, false);
                RenderActor(prefix + "-hands.png", Vector3.forward, true);
                RenderActor(prefix + "-left-hand.png", -Vector3.right + Vector3.forward * .6f, true, HumanBodyBones.LeftHand);
                RenderActor(prefix + "-right-hand.png", Vector3.right + Vector3.forward * .6f, true, HumanBodyBones.RightHand);
                var images = new List<string> { prefix + "-world.png", prefix + "-front.png", prefix + "-side.png", prefix + "-hands.png", prefix + "-left-hand.png", prefix + "-right-hand.png" };
                if (sampleIndex == 0)
                {
                    RenderActor(prefix + "-cover.png", Vector3.forward, false, null, true);
                    images.Add(prefix + "-cover.png");
                }
                sample.images = images.ToArray();
                samples.Add(sample);
                if (++sampleIndex < 3) { settleFrames = 0; return; }
                File.WriteAllText(Path.Combine(output, "pose-receipt.json"), JsonUtility.ToJson(new Receipt { samples = samples.ToArray() }, true));
                Finish(0);
            }
            catch (Exception error) { Debug.LogException(error); Finish(1); }
        }

        private static void Send(string method, string json) => receiver.OnFlutterCommand(JsonUtility.ToJson(new Envelope { method = method, json = json }));
        private static Vector3 Bone(HumanBodyBones bone) => animator.GetBoneTransform(bone).position;
        private static float Angle(HumanBodyBones top, HumanBodyBones joint, HumanBodyBones end) => Vector3.Angle(Bone(top) - Bone(joint), Bone(end) - Bone(joint));
        private static Sample Inspect(float time)
        {
            var value = new Sample { clipTime = time,
                leftElbowDegrees = Angle(HumanBodyBones.LeftUpperArm, HumanBodyBones.LeftLowerArm, HumanBodyBones.LeftHand),
                rightElbowDegrees = Angle(HumanBodyBones.RightUpperArm, HumanBodyBones.RightLowerArm, HumanBodyBones.RightHand),
                leftKneeDegrees = Angle(HumanBodyBones.LeftUpperLeg, HumanBodyBones.LeftLowerLeg, HumanBodyBones.LeftFoot),
                rightKneeDegrees = Angle(HumanBodyBones.RightUpperLeg, HumanBodyBones.RightLowerLeg, HumanBodyBones.RightFoot),
                leftHand = Bone(HumanBodyBones.LeftHand), rightHand = Bone(HumanBodyBones.RightHand), rootPosition = receiver.ActiveAvatarRoot.position };
            value.handSeparation = Vector3.Distance(value.leftHand, value.rightHand);
            if (value.leftElbowDegrees < 165 || value.rightElbowDegrees < 165 || value.leftKneeDegrees < 165 || value.rightKneeDegrees < 165 || value.handSeparation < .30f)
                throw new InvalidOperationException("The actual receiver still presents a folded/collapsed idle pose.");
            if (Vector3.Distance(value.rootPosition, initialRoot) > .03f || Quaternion.Angle(receiver.ActiveAvatarRoot.rotation, initialRotation) > .1f)
                throw new InvalidOperationException("Pose verification must not move or rotate the actor root.");
            return value;
        }

        private static void RenderWorld(string file) => SaveCamera(Camera.main, file, 720, 1280);
        private static void RenderActor(string file, Vector3 direction, bool hands, HumanBodyBones? handDetail = null, bool transparent = false)
        {
            Transform actor = receiver.ActiveAvatarRoot;
            Renderer[] renderers = actor.GetComponentsInChildren<Renderer>(true).Where(r => r.enabled && r.gameObject.activeInHierarchy).ToArray();
            Bounds bounds = renderers[0].bounds; foreach (Renderer renderer in renderers) bounds.Encapsulate(renderer.bounds);
            var objects = renderers.Select(r => r.gameObject).Distinct().ToArray();
            int[] layers = objects.Select(o => o.layer).ToArray();
            int captureLayer = Enumerable.Range(0, 32).Reverse().First(i => string.IsNullOrEmpty(LayerMask.LayerToName(i)));
            var go = new GameObject("PoseDiagnosticCamera") { hideFlags = HideFlags.HideAndDontSave };
            try
            {
                foreach (var obj in objects) obj.layer = captureLayer;
                var camera = go.AddComponent<Camera>(); camera.CopyFrom(Camera.main); camera.enabled = false;
                camera.cullingMask = 1 << captureLayer; camera.clearFlags = CameraClearFlags.SolidColor; camera.backgroundColor = transparent ? Color.clear : Color.white;
                camera.fieldOfView = 32f; camera.nearClipPlane = .01f;
                Vector3 focus = handDetail.HasValue ? Bone(handDetail.Value) + Vector3.down * .04f :
                    hands ? (Bone(HumanBodyBones.LeftHand) + Bone(HumanBodyBones.RightHand)) * .5f : bounds.center;
                float halfHeight = handDetail.HasValue ? .13f : hands ? .27f : bounds.extents.y * 1.12f;
                float distance = halfHeight / Mathf.Tan(camera.fieldOfView * Mathf.Deg2Rad * .5f);
                camera.transform.position = focus + direction.normalized * distance;
                camera.transform.LookAt(focus);
                SaveCamera(camera, file, hands ? 900 : 720, hands ? 700 : 1280, transparent);
            }
            finally
            {
                for (int i = 0; i < objects.Length; i++) objects[i].layer = layers[i];
                UnityEngine.Object.DestroyImmediate(go);
            }
        }

        private static void SaveCamera(Camera camera, string file, int width, int height, bool transparent = false)
        {
            RenderTexture oldTarget = camera.targetTexture, oldActive = RenderTexture.active;
            float oldAspect = camera.aspect;
            var target = new RenderTexture(width, height, 24, RenderTextureFormat.ARGB32) { antiAliasing = 4 };
            var image = new Texture2D(width, height, transparent ? TextureFormat.RGBA32 : TextureFormat.RGB24, false);
            try
            {
                target.Create(); camera.targetTexture = target; camera.aspect = (float)width / height;
                camera.Render(); RenderTexture.active = target;
                image.ReadPixels(new Rect(0, 0, width, height), 0, 0); image.Apply();
                File.WriteAllBytes(Path.Combine(output, file), image.EncodeToPNG());
            }
            finally
            {
                camera.targetTexture = oldTarget; camera.aspect = oldAspect; RenderTexture.active = oldActive;
                UnityEngine.Object.DestroyImmediate(image); target.Release(); UnityEngine.Object.DestroyImmediate(target);
            }
        }

        private static void Finish(int exit)
        {
            EditorApplication.update -= Tick; SessionState.SetBool(Session, false); EditorApplication.Exit(exit);
        }
    }
}
#endif
