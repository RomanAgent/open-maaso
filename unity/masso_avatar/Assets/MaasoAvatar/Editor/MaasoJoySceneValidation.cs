#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using Maaso.World;
using Maaso.World.Editor;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>Inspects the installed scene prefab. Never imports a raw VRM or saves a scene.</summary>
    public static class MaasoJoySceneValidation
    {
        private const string ScenePath = "Assets/MaasoAvatar/Scenes/Companion.unity";
        private const string ModelPath = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
        private const string ControllerPath = "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";
        private const BindingFlags PrivateInstance = BindingFlags.NonPublic | BindingFlags.Instance;

        [Serializable] private sealed class Command { public string method; public string json; }
        [Serializable] private sealed class Check { public string name; public bool passed; public string detail; }
        [Serializable] private sealed class ExpressionSample
        { public string name; public int changedVertices; public float maxVertexDelta; public int activeMorphs; }
        [Serializable] private sealed class MaterialSample
        { public string name, shader, assetPath, colorTexture, normalTexture; public int colorWidth, normalWidth; }
        [Serializable] private sealed class CaptureSample
        { public string path, sha256; public int width, height, msaaSamples; public float luminanceRange; public Vector3 position; public Vector3 euler; }
        [Serializable] private sealed class AvatarStateSample
        {
            public string stage;
            public string animatorJawName, rawJawName;
            public Quaternion animatorJawLocalRotation, rawJawLocalRotation;
            public Vector3 animatorJawPosition, rawJawPosition;
            public string[] activeMorphs;
        }
        [Serializable] private sealed class HandSkinSample
        {
            public string phase, side;
            public int vertexCount;
            public Vector3 wrist, rawWrist, bakedCentroid;
            public float rawToDrivenWristDistance, bakedCentroidToWristDistance, maximumBakedRadius;
        }
        [Serializable] private sealed class Report
        {
            public bool passed;
            public string source = "AssetDatabase-imported prefab bound in saved Companion.unity";
            public string sceneSha256Before, sceneSha256After, vrmSha256, prefabPath, controllerPath;
            public string failure;
            public string scope = "Editor scene, synthetic command samples. Each frame renders a temporary CPU BakeMesh snapshot of the installed prefab's current bones/morphs with its real materials. Synchronous Editor Camera.Render does not refresh GPU skinning reliably; this is not a player GPU, device performance, live TTS, or anatomical collision certification. Images require human review.";
            public string[] humanoidBones;
            public List<Check> checks = new();
            public List<ExpressionSample> expressions = new();
            public List<MaterialSample> materials = new();
            public List<CaptureSample> captures = new();
            public List<AvatarStateSample> avatarStates = new();
            public List<HandSkinSample> hands = new();
        }

        public static void RunFromCommandLine()
        {
            string output = Argument("-maasoJoyOutput", Path.GetFullPath(
                Path.Combine(Application.dataPath, "../../../docs/avatar/joy_model_audit/converted")));
            Directory.CreateDirectory(output);
            var report = new Report { sceneSha256Before = Sha256(ScenePath), vrmSha256 = Sha256(ModelPath) };
            GameObject faceCameraObject = null;
            bool opened = false;
            try
            {
                var scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
                opened = true;
                var receivers = Object.FindObjectsByType<UnityAvatarCommandReceiver>(FindObjectsInactive.Include);
                Require(report, "receiver", receivers.Length == 1, "Exactly one receiver must own the scene avatar.");
                var receiver = receivers[0];
                var serialized = new SerializedObject(receiver);
                Transform root = serialized.FindProperty("avatarRoot").objectReferenceValue as Transform;
                Require(report, "bound_root", root != null, "Receiver avatarRoot is assigned.");
                report.prefabPath = PrefabUtility.GetPrefabAssetPathOfNearestInstanceRoot(root.gameObject);
                Require(report, "installed_prefab", report.prefabPath == ModelPath, report.prefabPath);
                Vrm10Instance vrm = root.GetComponentInChildren<Vrm10Instance>(true);
                Animator animator = root.GetComponentInChildren<Animator>(true);
                Require(report, "humanoid", vrm != null && animator != null && animator.avatar != null &&
                    animator.avatar.isHuman && animator.avatar.isValid, "Imported Joy is a valid Humanoid VRM 1.0.");
                Require(report, "bundled_vrm_reference",
                    serialized.FindProperty("bundledVrmInstance").objectReferenceValue == vrm,
                    "Serialized bundledVrmInstance points to the installed Joy instance.");
                report.controllerPath = AssetDatabase.GetAssetPath(animator.runtimeAnimatorController);
                Require(report, "controller", report.controllerPath == ControllerPath, report.controllerPath);
                Camera mainCamera = scene.GetRootGameObjects()
                    .SelectMany(item => item.GetComponentsInChildren<Camera>(true))
                    .SingleOrDefault(camera => camera.CompareTag("MainCamera"));
                Require(report, "scene_camera", mainCamera != null, "Authored scene main camera exists.");
                mainCamera.scene = scene;
                FrontFullBodyCamera framing = mainCamera.GetComponent<FrontFullBodyCamera>();
                Require(report, "camera_target", framing != null && framing.TargetRoot == root,
                    "Existing framing component follows the installed avatar.");
                HumanBodyBones[] required = {
                    HumanBodyBones.Hips, HumanBodyBones.Spine, HumanBodyBones.Head,
                    HumanBodyBones.LeftEye, HumanBodyBones.RightEye,
                    HumanBodyBones.LeftUpperArm, HumanBodyBones.LeftLowerArm, HumanBodyBones.LeftHand,
                    HumanBodyBones.RightUpperArm, HumanBodyBones.RightLowerArm, HumanBodyBones.RightHand,
                    HumanBodyBones.LeftUpperLeg, HumanBodyBones.LeftLowerLeg, HumanBodyBones.LeftFoot,
                    HumanBodyBones.RightUpperLeg, HumanBodyBones.RightLowerLeg, HumanBodyBones.RightFoot,
                };
                var bones = new List<string>();
                for (int index = 0; index < (int)HumanBodyBones.LastBone; index++)
                {
                    Transform bone = animator.GetBoneTransform((HumanBodyBones)index);
                    if (bone != null) bones.Add((HumanBodyBones)index + "=" + bone.name);
                }
                report.humanoidBones = bones.ToArray();
                Require(report, "required_bones", required.All(bone => animator.GetBoneTransform(bone) != null),
                    "Head/eyes/hips/arms/hands/legs/feet are mapped; full mapping recorded separately.");
                foreach (HumanBodyBones bone in required)
                    Require(report, "finite_" + bone, Finite(animator.GetBoneTransform(bone).position), bone.ToString());
                Require(report, "arm_hierarchy",
                    animator.GetBoneTransform(HumanBodyBones.LeftHand).IsChildOf(animator.GetBoneTransform(HumanBodyBones.LeftUpperArm)) &&
                    animator.GetBoneTransform(HumanBodyBones.RightHand).IsChildOf(animator.GetBoneTransform(HumanBodyBones.RightUpperArm)),
                    "Both hands descend from their humanoid upper arm, allowing intervening twist bones.");
                ReadMaterials(root, report);
                RecordAvatarState("loaded_before_runtime", animator, vrm, report);

                // Companion loads this Resources prefab at runtime. EditMode does not run
                // that startup, nor grant avatar visibility, so use the established room
                // preview initializer instead of rendering an uninitialized empty scene.
                Invoke(receiver, "Awake");
                Require(report, "active_receiver_root", receiver.ActiveAvatarRoot == root, "Awake retained the imported prefab.");
                RecordAvatarState("after_receiver_awake", animator, vrm, report);
                // Runtime is initialized by binding before this diagnostic Rebind,
                // preserving the constraint rest state. The existing initializer
                // below then samples the actual authored idle as usual.
                animator.Rebind();
                animator.Update(0f);
                RecordAvatarState("after_rebind_before_process", animator, vrm, report);
                vrm.Runtime.Process();
                RecordAvatarState("after_rebind_and_process", animator, vrm, report);
                GameObject mapAsset = Resources.Load<GameObject>(PersistentWorldMapController.ResourceName);
                Require(report, "runtime_map_asset", mapAsset != null, PersistentWorldMapController.ResourceName);
                GameObject mapObject = PrefabUtility.InstantiatePrefab(mapAsset, scene) as GameObject;
                PersistentWorldMapController map = mapObject != null
                    ? mapObject.GetComponent<PersistentWorldMapController>() : null;
                Require(report, "runtime_map_instance", map != null, "The shipped coastal room prefab is instantiated temporarily.");
                MethodInfo prepare = typeof(PersonalSpaceSceneBuilder).GetMethod("PrepareRuntimePortrait",
                    BindingFlags.NonPublic | BindingFlags.Static);
                if (prepare == null) throw new MissingMethodException(nameof(PersonalSpaceSceneBuilder), "PrepareRuntimePortrait");
                prepare.Invoke(null, new object[] { mainCamera, map });
                animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
                animator.applyRootMotion = false;
                foreach (SkinnedMeshRenderer renderer in root.GetComponentsInChildren<SkinnedMeshRenderer>(true))
                    renderer.updateWhenOffscreen = true;
                // Freeze the blink schedule while taking neutral and mouth samples.
                SetField(receiver, "blinkStartedAt", -1f);
                SetField(receiver, "nextBlinkAt", Time.realtimeSinceStartup + 3600f);
                SetExpression(receiver, vrm, "{\"eyeOpen\":1}");
                RecordAvatarState("neutral", animator, vrm, report);
                AvatarStateSample loadedState = report.avatarStates.Single(state => state.stage == "loaded_before_runtime");
                AvatarStateSample neutralState = report.avatarStates.Single(state => state.stage == "neutral");
                float neutralJawError = Quaternion.Angle(loadedState.rawJawLocalRotation, neutralState.rawJawLocalRotation);
                Require(report, "silent_jaw_preserves_imported_neutral",
                    !string.IsNullOrEmpty(neutralState.rawJawName) && neutralJawError < .1f,
                    neutralJawError + " degrees of extra jaw opening after Animator and receiver processing.");
                SkinnedMeshRenderer[] skinned = root.GetComponentsInChildren<SkinnedMeshRenderer>(true);
                Vector3[][] neutral = Bake(skinned);

                float previousAspect = mainCamera.aspect;
                try
                {
                    mainCamera.aspect = 9f / 16f;
                    framing.FrameNow();
                    PortraitDepthOfField portrait = mainCamera.GetComponent<PortraitDepthOfField>();
                    Require(report, "portrait_effect", portrait != null, "The shipped Home portrait effect exists.");
                    portrait.enabled = true;
                    Require(report, "portrait_focus", portrait.UpdateFocus() && portrait.CanRender,
                        "Portrait focus can render the visible installed avatar.");
                    RequireVisible(report, "visible_avatar", mainCamera, skinned);
                    RequireVisible(report, "visible_coastal_room", mainCamera,
                        mapObject.GetComponentsInChildren<Renderer>(false));
                    Capture(mainCamera, output, "Joy-in-room.png", 900, 1600, report, root);
                    faceCameraObject = new GameObject("JoyValidationTemporaryFaceCamera")
                        { hideFlags = HideFlags.HideAndDontSave };
                    Camera faceCamera = faceCameraObject.AddComponent<Camera>();
                    faceCamera.CopyFrom(mainCamera);
                    faceCamera.scene = scene;
                    faceCamera.enabled = false;
                    faceCamera.targetTexture = null;
                    faceCamera.aspect = 1f;
                    faceCamera.nearClipPlane = 0.01f;
                    faceCamera.fieldOfView = 28f;
                    Vector3 focus = (animator.GetBoneTransform(HumanBodyBones.LeftEye).position +
                        animator.GetBoneTransform(HumanBodyBones.RightEye).position) * .5f - Vector3.up * .025f;
                    Vector3 direction = mainCamera.transform.position - focus;
                    direction.y = 0f;
                    if (direction.sqrMagnitude < 1e-6f) direction = root.forward;
                    faceCamera.transform.position = focus + direction.normalized * .62f;
                    faceCamera.transform.LookAt(focus, Vector3.up);
                    RequireVisible(report, "visible_face", faceCamera, skinned);
                    Capture(faceCamera, output, "Joy-in-room-face.png", 900, 900, report, root);
                    Vector3 facePosition = faceCamera.transform.position;
                    Quaternion faceRotation = faceCamera.transform.rotation;
                    float faceFov = faceCamera.fieldOfView;
                    Vector3 thumbnailFocus = focus - Vector3.up * .11f;
                    faceCamera.transform.position = thumbnailFocus + direction.normalized * 1f;
                    faceCamera.transform.LookAt(thumbnailFocus, Vector3.up);
                    faceCamera.fieldOfView = 32f;
                    // This close-up is an expression diagnostic, never a model-store cover.
                    Capture(faceCamera, output, "Joy-face-thumbnail-diagnostic.png", 512, 512, report, root, true);
                    faceCamera.transform.SetPositionAndRotation(facePosition, faceRotation);
                    faceCamera.fieldOfView = faceFov;

                    Send(receiver, "setMouthOpen", "{\"value\":0.8}");
                    ProcessReceiver(receiver, vrm);
                    RecordAvatarState("mouth_aa_0.8", animator, vrm, report);
                    RecordExpression("mouth_aa_0.8", skinned, neutral, report);
                    Capture(mainCamera, output, "Joy-in-room-mouth.png", 900, 1600, report, root);
                    Capture(faceCamera, output, "Joy-in-room-face-mouth.png", 900, 900, report, root);
                    Send(receiver, "setMouthOpen", "{\"value\":0}");
                    // A completely zero expression is the legacy default-open command.
                    // Sample the real scheduled blink at peak closure, changing only its
                    // clock origin; LateUpdate still owns all expression/morph writes.
                    float duration = Mathf.Max(.05f, Field<float>(receiver, "blinkDurationSeconds"));
                    FieldInfo closingField = typeof(UnityAvatarCommandReceiver).GetField("BlinkClosingFraction",
                        BindingFlags.NonPublic | BindingFlags.Static);
                    if (closingField == null) throw new MissingFieldException(nameof(UnityAvatarCommandReceiver), "BlinkClosingFraction");
                    float closingFraction = (float)closingField.GetRawConstantValue();
                    SetField(receiver, "autoBlink", true);
                    SetField(receiver, "blinkStartedAt", Time.realtimeSinceStartup - duration * closingFraction);
                    ProcessReceiver(receiver, vrm);
                    Require(report, "blink_runtime_weight", Field<float>(receiver, "autoBlinkWeight") > .95f,
                        "Receiver.LateUpdate produced the actual automatic blink before VRM processing.");
                    RecordAvatarState("blink_closed", animator, vrm, report);
                    RecordExpression("blink_closed", skinned, neutral, report);
                    Capture(mainCamera, output, "Joy-in-room-blink.png", 900, 1600, report, root);
                    Capture(faceCamera, output, "Joy-in-room-face-blink.png", 900, 900, report, root);
                    SetField(receiver, "blinkStartedAt", -1f);
                    SetField(receiver, "autoBlinkWeight", 0f);
                    SetField(receiver, "nextBlinkAt", Time.realtimeSinceStartup + 3600f);
                    SetExpression(receiver, vrm, "{\"eyeOpen\":1}");

                    SamplePhone(receiver, vrm, animator, mainCamera, output, report);
                    Require(report, "visible_expression_changes", report.captures
                        .Where(item => Path.GetFileName(item.path).StartsWith("Joy-in-room-face", StringComparison.Ordinal))
                        .Select(item => item.sha256).Distinct().Count() == 3,
                        "Neutral, mouth and blink must produce three distinct face images; frozen GPU snapshots cannot pass.");
                }
                finally { mainCamera.aspect = previousAspect; }
                Require(report, "rendered_pixels", report.captures.All(item => item.luminanceRange > .05f),
                    "Each captured frame contains varying visible pixels; appearance still requires review.");
            }
            catch (Exception error)
            {
                report.failure = error.ToString();
                Debug.LogException(error);
            }
            finally
            {
                if (faceCameraObject != null) Object.DestroyImmediate(faceCameraObject);
                // Discard temporary animation, face and phone samples. Never SaveScene/SaveAssets.
                if (opened) EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
                report.sceneSha256After = Sha256(ScenePath);
                report.checks.Add(new Check { name = "scene_file_unchanged", passed =
                    report.sceneSha256Before == report.sceneSha256After, detail = report.sceneSha256After });
                report.passed = report.failure == null && report.checks.All(check => check.passed);
                File.WriteAllText(Path.Combine(output, "Joy-scene-validation.json"), JsonUtility.ToJson(report, true));
            }
            if (!report.passed) throw new InvalidOperationException("Joy scene validation failed; inspect Joy-scene-validation.json.");
            Debug.Log("[JoySceneValidation] PASS imported scene prefab; " + report.captures.Count + " captures in " + output);
        }

        private static void SamplePhone(UnityAvatarCommandReceiver receiver, Vrm10Instance vrm,
            Animator animator, Camera camera, string output, Report report)
        {
            Transform root = receiver.ActiveAvatarRoot;
            Vector3 rightBefore = animator.GetBoneTransform(HumanBodyBones.RightHand).position;
            HandSkinSample leftNeutral = SampleHandSkin("neutral", true, animator, vrm, root, report);
            HandSkinSample rightNeutral = SampleHandSkin("neutral", false, animator, vrm, root, report);
            string interaction = "joy-scene-validation";
            void Command(string phase, int sequence) => Send(receiver, "setPhoneInteraction", JsonUtility.ToJson(
                new AvatarPhoneCommand { requestId = interaction + sequence, interactionId = interaction,
                    phase = phase, sequence = sequence,
                    expiresAtMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 9000 }));
            Command("reading", 1);
            var phone = typeof(UnityAvatarCommandReceiver).GetField("phoneInteraction", PrivateInstance)
                ?.GetValue(receiver) as AvatarPhoneInteractionController;
            Require(report, "phone_controller", phone != null && phone.OwnsHands, "Real bridge accepted a reading interaction.");
            float started = Time.realtimeSinceStartup;
            long startedEpoch = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            foreach (float t in new[] { .35f, .7f, 1.2f })
            {
                // Render duration is irrelevant to the synthetic action timeline.
                phone.Advance(started + t, startedEpoch + (long)(t * 1000f));
                vrm.Runtime.Process();
                CheckHandSkin("reading_" + t, true, animator, vrm, root, leftNeutral, report);
                Capture(camera, output, "Joy-in-room-phone-reading-" + Mathf.RoundToInt(t * 100) + ".png", 900, 1600, report, root);
            }
            Require(report, "phone_reading", phone.Phone != null && phone.Phone.activeInHierarchy && phone.Phase == "reading",
                "Phone prop visible after the pickup transition.");
            CheckGripTarget(phone, animator, true, report);
            Command("replying", 2);
            phone.Advance(Time.realtimeSinceStartup + .5f, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            vrm.Runtime.Process();
            CheckHandSkin("replying", true, animator, vrm, root, leftNeutral, report);
            CheckHandSkin("replying", false, animator, vrm, root, rightNeutral, report);
            Capture(camera, output, "Joy-in-room-phone-replying.png", 900, 1600, report, root);
            Require(report, "phone_replying", phone.Phase == "replying" && phone.OwnsHands &&
                Vector3.Distance(rightBefore, animator.GetBoneTransform(HumanBodyBones.RightHand).position) > .02f,
                "Reply phase moves the other hand; inspect screenshot for hand/prop geometry.");
            CheckGripTarget(phone, animator, true, report);
            CheckGripTarget(phone, animator, false, report);
            Command("none", 3);
            phone.Advance(Time.realtimeSinceStartup + 1f, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            Require(report, "phone_release", !phone.OwnsHands && !phone.Phone.activeSelf, "Phone and overlay relinquish ownership.");
        }

        private static void CheckGripTarget(AvatarPhoneInteractionController phone, Animator animator,
            bool left, Report report)
        {
            MethodInfo method = typeof(AvatarPhoneInteractionController).GetMethod("GripWrist", PrivateInstance);
            if (method == null) throw new MissingMethodException(nameof(AvatarPhoneInteractionController), "GripWrist");
            Vector3 target = (Vector3)method.Invoke(phone,
                new object[] { left, phone.Phone.transform.position, phone.Phone.transform.rotation });
            float error = Vector3.Distance(target,
                animator.GetBoneTransform(left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand).position);
            Require(report, "phone_" + phone.Phase + (left ? "_left" : "_right") + "_grip_target",
                error < .001f, error.ToString("F7") + "m IK residual; visual contact/collisions still require review.");
        }

        private static void RecordAvatarState(string stage, Animator animator, Vrm10Instance vrm, Report report)
        {
            Transform jaw = animator.GetBoneTransform(HumanBodyBones.Jaw);
            vrm.TryGetBoneTransform(HumanBodyBones.Jaw, out Transform rawJaw);
            var morphs = new List<string>();
            foreach (SkinnedMeshRenderer renderer in vrm.GetComponentsInChildren<SkinnedMeshRenderer>(true))
                for (int index = 0; index < renderer.sharedMesh.blendShapeCount; index++)
                {
                    float weight = renderer.GetBlendShapeWeight(index);
                    if (Mathf.Abs(weight) > .001f)
                        morphs.Add(renderer.name + "/" + renderer.sharedMesh.GetBlendShapeName(index) + "=" + weight);
                }
            report.avatarStates.Add(new AvatarStateSample { stage = stage,
                animatorJawName = jaw != null ? jaw.name : null,
                rawJawName = rawJaw != null ? rawJaw.name : null,
                animatorJawLocalRotation = jaw != null ? jaw.localRotation : Quaternion.identity,
                rawJawLocalRotation = rawJaw != null ? rawJaw.localRotation : Quaternion.identity,
                animatorJawPosition = jaw != null ? jaw.position : Vector3.zero,
                rawJawPosition = rawJaw != null ? rawJaw.position : Vector3.zero,
                activeMorphs = morphs.ToArray() });
        }

        private static HandSkinSample SampleHandSkin(string phase, bool left, Animator animator,
            Vrm10Instance vrm, Transform root, Report report)
        {
            HumanBodyBones handId = left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand;
            Transform wrist = animator.GetBoneTransform(handId);
            Require(report, phase + "_raw_" + handId,
                vrm.TryGetBoneTransform(handId, out Transform rawWrist) && rawWrist != null,
                "The original deforming hand bone is mapped independently of the Animator control rig.");
            var sample = new HandSkinSample { phase = phase, side = left ? "left" : "right",
                wrist = wrist.position, rawWrist = rawWrist.position,
                rawToDrivenWristDistance = Vector3.Distance(wrist.position, rawWrist.position) };
            foreach (SkinnedMeshRenderer renderer in root.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                BoneWeight[] weights = renderer.sharedMesh.boneWeights;
                Transform[] bones = renderer.bones;
                bool[] handBones = bones.Select(bone => bone != null &&
                    (bone == rawWrist || bone.IsChildOf(rawWrist))).ToArray();
                if (!handBones.Any(value => value)) continue;
                var mesh = new Mesh();
                try
                {
                    renderer.BakeMesh(mesh);
                    Vector3[] vertices = mesh.vertices;
                    Require(report, phase + "_skin_weight_count_" + renderer.name,
                        weights.Length == vertices.Length, "Every sampled skin vertex has bone weights.");
                    for (int index = 0; index < vertices.Length; index++)
                    {
                        BoneWeight weight = weights[index];
                        float HandWeight(int boneIndex, float value) =>
                            boneIndex >= 0 && boneIndex < handBones.Length && handBones[boneIndex] ? value : 0f;
                        float total = HandWeight(weight.boneIndex0, weight.weight0) + HandWeight(weight.boneIndex1, weight.weight1) +
                            HandWeight(weight.boneIndex2, weight.weight2) + HandWeight(weight.boneIndex3, weight.weight3);
                        if (total < .95f) continue;
                        Vector3 point = renderer.transform.TransformPoint(vertices[index]);
                        sample.vertexCount++;
                        sample.bakedCentroid += point;
                        sample.maximumBakedRadius = Mathf.Max(sample.maximumBakedRadius, Vector3.Distance(point, wrist.position));
                    }
                }
                finally { Object.DestroyImmediate(mesh); }
            }
            Require(report, phase + "_skin_vertices_" + sample.side, sample.vertexCount > 10,
                sample.vertexCount + " actual baked vertices are at least 95% owned by this hand/fingers.");
            sample.bakedCentroid /= sample.vertexCount;
            sample.bakedCentroidToWristDistance = Vector3.Distance(sample.bakedCentroid, wrist.position);
            report.hands.Add(sample);
            return sample;
        }

        private static void CheckHandSkin(string phase, bool left, Animator animator, Vrm10Instance vrm,
            Transform root, HandSkinSample neutral, Report report)
        {
            HandSkinSample current = SampleHandSkin(phase, left, animator, vrm, root, report);
            Require(report, phase + "_deforming_wrist_" + current.side,
                current.rawToDrivenWristDistance < .003f,
                current.rawToDrivenWristDistance + "m between the driven humanoid wrist and original skin bone.");
            // Finger bends may change the centroid but cannot leave the entire hand
            // behind at the idle hip while its driven wrist approaches the phone.
            Require(report, phase + "_baked_hand_follows_" + current.side,
                current.bakedCentroidToWristDistance <= neutral.maximumBakedRadius + .005f,
                "Actual baked hand centroid/wrist distance=" + current.bakedCentroidToWristDistance +
                "m; neutral measured full-hand radius=" + neutral.maximumBakedRadius + "m.");
        }

        private static void SetExpression(UnityAvatarCommandReceiver receiver, Vrm10Instance vrm, string json)
        {
            Send(receiver, "setExpression", json);
            Invoke(receiver, "UpdateExpressionTransition", Time.realtimeSinceStartup + 1f);
            ProcessReceiver(receiver, vrm);
        }

        private static void ProcessReceiver(UnityAvatarCommandReceiver receiver, Vrm10Instance vrm)
        {
            Invoke(receiver, "LateUpdate");
            vrm.Runtime.Process();
        }

        private static void RequireVisible(Report report, string name, Camera camera, IEnumerable<Renderer> renderers)
        {
            Plane[] frustum = GeometryUtility.CalculateFrustumPlanes(camera);
            int count = renderers.Count(renderer => renderer.enabled && !renderer.forceRenderingOff &&
                renderer.gameObject.activeInHierarchy && (camera.cullingMask & (1 << renderer.gameObject.layer)) != 0 &&
                GeometryUtility.TestPlanesAABB(frustum, renderer.bounds));
            Require(report, name, count > 0, count + " active renderers intersect the capture camera frustum.");
        }

        private static Vector3[][] Bake(SkinnedMeshRenderer[] renderers) => renderers.Select(renderer =>
        {
            var mesh = new Mesh();
            try { renderer.BakeMesh(mesh); return mesh.vertices; }
            finally { Object.DestroyImmediate(mesh); }
        }).ToArray();

        private static void RecordExpression(string name, SkinnedMeshRenderer[] renderers,
            Vector3[][] neutral, Report report)
        {
            Vector3[][] current = Bake(renderers);
            var sample = new ExpressionSample { name = name };
            for (int mesh = 0; mesh < current.Length; mesh++)
            {
                if (current[mesh].Length != neutral[mesh].Length)
                    throw new InvalidOperationException("Expression unexpectedly changed mesh topology.");
                for (int vertex = 0; vertex < current[mesh].Length; vertex++)
                {
                    float delta = Vector3.Distance(current[mesh][vertex], neutral[mesh][vertex]);
                    if (delta > 1e-6f) sample.changedVertices++;
                    sample.maxVertexDelta = Mathf.Max(sample.maxVertexDelta, delta);
                }
                for (int morph = 0; morph < renderers[mesh].sharedMesh.blendShapeCount; morph++)
                    if (renderers[mesh].GetBlendShapeWeight(morph) > .001f) sample.activeMorphs++;
            }
            report.expressions.Add(sample);
            Require(report, "expression_" + name, sample.changedVertices > 0 && sample.maxVertexDelta > 1e-5f,
                sample.changedVertices + " vertices changed by up to " + sample.maxVertexDelta + "m.");
        }

        private static void ReadMaterials(Transform root, Report report)
        {
            Material[] materials = root.GetComponentsInChildren<Renderer>(true)
                .SelectMany(renderer => renderer.sharedMaterials).Distinct().ToArray();
            Require(report, "materials", materials.Length > 0 && materials.All(material => material != null &&
                material.shader != null && material.shader.name != "Hidden/InternalErrorShader"),
                "Imported renderers have material and shader references.");
            foreach (Material material in materials)
            {
                Texture color = material.mainTexture;
                Texture normal = material.HasProperty("_BumpMap") ? material.GetTexture("_BumpMap") : null;
                report.materials.Add(new MaterialSample { name = material.name, shader = material.shader.name,
                    assetPath = AssetDatabase.GetAssetPath(material), colorTexture = color?.name,
                    colorWidth = color != null ? color.width : 0, normalTexture = normal?.name,
                    normalWidth = normal != null ? normal.width : 0 });
            }
        }

        private static void Capture(Camera camera, string output, string name, int width, int height, Report report,
            Transform avatarRoot, bool avatarOnly = false)
        {
            var target = new RenderTexture(width, height, 24, RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB)
                { antiAliasing = 4 };
            var pixels = new Texture2D(width, height, TextureFormat.RGB24, false, false);
            RenderTexture previousTarget = camera.targetTexture, previousActive = RenderTexture.active;
            int previousCullingMask = camera.cullingMask;
            CameraClearFlags previousClearFlags = camera.clearFlags;
            Color previousBackground = camera.backgroundColor;
            var snapshots = new List<GameObject>();
            var meshes = new List<Mesh>();
            var sourceVisibility = new Dictionary<SkinnedMeshRenderer, bool>();
            try
            {
                int isolatedLayer = -1;
                if (avatarOnly)
                {
                    var usedLayers = new HashSet<int>(Object.FindObjectsByType<Renderer>(FindObjectsInactive.Include)
                        .Select(renderer => renderer.gameObject.layer));
                    for (int layer = 30; layer >= 8; layer--)
                        if (!usedLayers.Contains(layer)) { isolatedLayer = layer; break; }
                    Require(report, "thumbnail_isolation_layer", isolatedLayer >= 0,
                        "A verified unused scene layer isolates the temporary avatar skin; no room geometry is included.");
                    camera.cullingMask = 1 << isolatedLayer;
                    camera.clearFlags = CameraClearFlags.SolidColor;
                    camera.backgroundColor = Color.white;
                }
                // A synchronous Editor executeMethod has no player skinning update
                // between Camera.Render calls. Use the exact current CPU skin from
                // the installed prefab, as the existing phone geometry captures do.
                // Materials, object transforms, room, lighting and camera stay real.
                foreach (SkinnedMeshRenderer source in avatarRoot.GetComponentsInChildren<SkinnedMeshRenderer>(false))
                {
                    if (!source.enabled || source.forceRenderingOff || source.sharedMesh == null) continue;
                    var mesh = new Mesh { name = source.name + "_CurrentCpuSkin" };
                    meshes.Add(mesh);
                    source.BakeMesh(mesh);
                    var snapshot = new GameObject(source.name + "_ValidationSkinSnapshot")
                        { hideFlags = HideFlags.HideAndDontSave,
                            layer = isolatedLayer >= 0 ? isolatedLayer : source.gameObject.layer };
                    snapshots.Add(snapshot);
                    snapshot.transform.SetParent(source.transform, false);
                    snapshot.AddComponent<MeshFilter>().sharedMesh = mesh;
                    MeshRenderer renderer = snapshot.AddComponent<MeshRenderer>();
                    renderer.sharedMaterials = source.sharedMaterials;
                    renderer.shadowCastingMode = source.shadowCastingMode;
                    renderer.receiveShadows = source.receiveShadows;
                    renderer.lightProbeUsage = source.lightProbeUsage;
                    renderer.reflectionProbeUsage = source.reflectionProbeUsage;
                    sourceVisibility[source] = source.forceRenderingOff;
                    source.forceRenderingOff = true;
                }
                Require(report, "sampled_skin_" + name, snapshots.Count > 0,
                    snapshots.Count + " actual imported skinned renderers baked for this frame.");
                target.Create();
                camera.targetTexture = target;
                camera.Render();
                RenderTexture.active = target;
                pixels.ReadPixels(new Rect(0, 0, width, height), 0, 0);
                pixels.Apply();
                string path = Path.Combine(output, name);
                File.WriteAllBytes(path, pixels.EncodeToPNG());
                Color32[] colors = pixels.GetPixels32();
                float minimum = 1f, maximum = 0f;
                for (int index = 0; index < colors.Length; index += 97)
                {
                    Color32 pixel = colors[index];
                    float luma = (.2126f * pixel.r + .7152f * pixel.g + .0722f * pixel.b) / 255f;
                    minimum = Mathf.Min(minimum, luma); maximum = Mathf.Max(maximum, luma);
                }
                report.captures.Add(new CaptureSample { path = path, width = width, height = height,
                    sha256 = Sha256(path), msaaSamples = target.antiAliasing,
                    luminanceRange = maximum - minimum, position = camera.transform.position, euler = camera.transform.eulerAngles });
                Require(report, "pixels_" + name, maximum - minimum > .05f,
                    "Luminance range " + (maximum - minimum) + "; a blank frame fails immediately.");
            }
            finally
            {
                camera.targetTexture = previousTarget; RenderTexture.active = previousActive;
                camera.cullingMask = previousCullingMask;
                camera.clearFlags = previousClearFlags;
                camera.backgroundColor = previousBackground;
                foreach (var source in sourceVisibility) source.Key.forceRenderingOff = source.Value;
                foreach (GameObject snapshot in snapshots) Object.DestroyImmediate(snapshot);
                foreach (Mesh mesh in meshes) Object.DestroyImmediate(mesh);
                target.Release();
                Object.DestroyImmediate(pixels); Object.DestroyImmediate(target);
            }
        }

        private static void Require(Report report, string name, bool passed, string detail)
        {
            report.checks.Add(new Check { name = name, passed = passed, detail = detail });
            if (!passed) throw new InvalidOperationException(name + ": " + detail);
        }
        private static bool Finite(Vector3 value) => !float.IsNaN(value.x + value.y + value.z) &&
            !float.IsInfinity(value.x) && !float.IsInfinity(value.y) && !float.IsInfinity(value.z);
        private static void Send(UnityAvatarCommandReceiver receiver, string method, string json) =>
            receiver.OnFlutterCommand(JsonUtility.ToJson(new Command { method = method, json = json }));
        private static void Invoke(object target, string method, params object[] arguments)
        {
            MethodInfo function = target.GetType().GetMethod(method, PrivateInstance, null,
                arguments.Select(argument => argument.GetType()).ToArray(), null);
            if (function == null) throw new MissingMethodException(target.GetType().Name, method);
            function.Invoke(target, arguments);
        }
        private static T Field<T>(object target, string name)
        {
            FieldInfo field = target.GetType().GetField(name, PrivateInstance);
            if (field == null) throw new MissingFieldException(target.GetType().Name, name);
            return (T)field.GetValue(target);
        }
        private static void SetField(object target, string name, object value)
        {
            FieldInfo field = target.GetType().GetField(name, PrivateInstance);
            if (field == null) throw new MissingFieldException(target.GetType().Name, name);
            field.SetValue(target, value);
        }
        private static string Sha256(string path)
        { using var hash = SHA256.Create(); return BitConverter.ToString(hash.ComputeHash(File.ReadAllBytes(path))).Replace("-", "").ToLowerInvariant(); }
        private static string Argument(string key, string fallback)
        { string[] args = Environment.GetCommandLineArgs(); int index = Array.IndexOf(args, key); return index >= 0 && index + 1 < args.Length ? args[index + 1] : fallback; }
    }
}
#endif
