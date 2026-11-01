#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>Offline comparison of source FK and the shipped deforming hand.
    /// Captures temporary baked meshes; never saves models, clips or scenes.</summary>
    public static class MaasoHandPoseAudit
    {
        private const string Controller = "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";
        private const string Source = MaasoOpenAnnieMotionImporter.SourceDirectory;
        private const BindingFlags Private = BindingFlags.Static | BindingFlags.NonPublic;
        private static readonly HumanBodyBones[] HandBones = Enum.GetValues(typeof(HumanBodyBones))
            .Cast<HumanBodyBones>().Where(b => b != HumanBodyBones.LastBone).ToArray();

        public static void Run()
        {
            string[] args = Environment.GetCommandLineArgs();
            int index = Array.IndexOf(args, "-maasoHandAuditOutput");
            string output = index >= 0 ? args[index + 1] : "Builds/Preview/HandAudit";
            Directory.CreateDirectory(output);
            var samples = new JArray();
            foreach (string name in new[] { "idle_c", "listen_b", "wave" })
            {
                samples.Add(Capture(output, name, true));
                samples.Add(Capture(output, name, false));
            }
            File.WriteAllText(Path.Combine(output, "receipt.json"), new JObject
            {
                ["scope"] = "Installed Joy source FK versus native controller, actual raw bones and CPU BakeMesh. Editor diagnostic, not physical iOS rendering or an anatomical certification.",
                ["samples"] = samples,
            }.ToString());
            Debug.Log("[MaasoHandAudit] Captured " + output);
        }

        private static JObject Capture(string output, string name, bool sourceFk)
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            GameObject root = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(
                "Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            root.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            var vrm = root.GetComponent<Vrm10Instance>();
            vrm.enabled = false;
            Animator animator = root.GetComponentInChildren<Animator>();
            animator.applyRootMotion = false;
            animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(Controller);
            Vrm10RuntimeControlRig rig = null;
            UnityEngine.Avatar generated = null;
            try
            {
                if (sourceFk)
                {
                    animator.runtimeAnimatorController = null;
                    rig = new Vrm10RuntimeControlRig(vrm.Humanoid, root.transform);
                    generated = rig.ControlRigAnimator.avatar;
                    JObject pack = JObject.Parse(File.ReadAllText(Source + "/pack.json"));
                    JObject data = JObject.Parse(File.ReadAllText(Source + "/" + name + ".json"));
                    int frame = Mathf.RoundToInt(((int)data["frames"] - 1) * .5f);
                    foreach (var bone in rig.Bones.Values) bone.ControlBone.localRotation = Quaternion.identity;
                    foreach (JProperty hand in ((JObject)pack["hands"]).Properties())
                    {
                        MaasoOpenAnnieMotionImporter.TryMapBone(hand.Name, out HumanBodyBones id);
                        rig.Bones[id].ControlBone.localRotation = MaasoOpenAnnieMotionImporter.SourceQuaternion(hand.Value.ToObject<float[]>(), 0);
                    }
                    foreach (JProperty track in ((JObject)data["bones"]).Properties())
                    {
                        MaasoOpenAnnieMotionImporter.TryMapBone(track.Name, out HumanBodyBones id);
                        rig.Bones[id].ControlBone.localRotation = MaasoOpenAnnieMotionImporter.SourceQuaternion(track.Value.ToObject<float[]>(), frame * 4);
                    }
                    typeof(Vrm10RuntimeControlRig).GetMethod("Process", BindingFlags.Instance | BindingFlags.NonPublic)
                        .Invoke(rig, null);
                }
                else
                {
                    _ = vrm.Runtime;
                    animator.Rebind();
                    animator.Play("Base Layer.annie_" + name, 0, .5f);
                    animator.Update(0f);
                    vrm.Runtime.Process();
                    if (Environment.GetCommandLineArgs().Contains("-maasoHandAuditCorrected"))
                    {
                        var deformation = root.AddComponent<AvatarRigifyArmDeformation>();
                        if (!deformation.Bind(root.transform)) throw new InvalidOperationException("Joy arm deformation rig did not bind.");
                        deformation.ApplyAfterVrm();
                    }
                }
                var row = new JObject { ["mode"] = sourceFk ? "source-fk" : "native-controller",
                    ["clip"] = name, ["bones"] = new JObject(),
                    ["deformationCorrection"] = !sourceFk && Environment.GetCommandLineArgs().Contains("-maasoHandAuditCorrected"),
                    ["runtimeControlRig"] = sourceFk || vrm.Runtime.ControlRig != null };
                var boneRows = (JObject)row["bones"];
                foreach (HumanBodyBones id in HandBones)
                {
                    Transform raw = vrm.Humanoid.GetBoneTransform(id);
                    if (raw == null) continue;
                    boneRows[id.ToString()] = new JObject
                    {
                        ["localRotation"] = JArray.FromObject(new[] { raw.localRotation.x, raw.localRotation.y, raw.localRotation.z, raw.localRotation.w }),
                        ["position"] = JArray.FromObject(new[] { raw.position.x, raw.position.y, raw.position.z }),
                        ["rawName"] = raw.name,
                        ["worldMatrix"] = MatrixRows(raw.localToWorldMatrix),
                    };
                }
                var deformers = new JObject();
                foreach (Transform transform in root.GetComponentsInChildren<Transform>(true))
                    if (new[] { "DEF-upper_arm", "DEF-forearm", "DEF-elbow", "DEF-hand" }
                        .Any(prefix => transform.name.StartsWith(prefix, StringComparison.Ordinal)))
                        deformers[transform.name] = new JObject
                        {
                            ["worldMatrix"] = MatrixRows(transform.localToWorldMatrix),
                            ["parent"] = transform.parent != null ? transform.parent.name : string.Empty,
                            ["localScale"] = JArray.FromObject(new[] { transform.localScale.x, transform.localScale.y, transform.localScale.z }),
                        };
                row["deformers"] = deformers;
                using (var handler = new HumanPoseHandler(animator.avatar, root.transform))
                {
                    var pose = new HumanPose(); handler.GetHumanPose(ref pose);
                    var muscles = new JObject();
                    for (int i = 0; i < HumanTrait.MuscleCount; i++)
                        if (HumanTrait.MuscleName[i].Contains("Thumb") ||
                            HumanTrait.MuscleName[i].Contains("Hand")) muscles[HumanTrait.MuscleName[i]] = pose.muscles[i];
                    row["muscles"] = muscles;
                }
                Camera camera = (Camera)typeof(MaasoSpeechPerformanceReplay).GetMethod("CreateCamera", Private)
                    .Invoke(null, new object[] { root });
                var files = new JArray();
                foreach (string view in new[] { "body", "left", "right" })
                {
                    if (view != "body")
                    {
                        Transform hand = vrm.Humanoid.GetBoneTransform(view == "left" ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand);
                        Transform finger = vrm.Humanoid.GetBoneTransform(view == "left" ? HumanBodyBones.LeftMiddleProximal : HumanBodyBones.RightMiddleProximal);
                        Vector3 center = Vector3.Lerp(hand.position, finger.position, .6f);
                        camera.transform.position = center + new Vector3(view == "left" ? .10f : -.10f, .07f, .45f);
                        camera.transform.LookAt(center);
                    }
                    string file = name + "-" + (sourceFk ? "source" : "native") + "-" + view + ".png";
                    typeof(MaasoSpeechPerformanceReplay).GetMethod("Render", Private)
                        .Invoke(null, new object[] { camera, root, Path.Combine(output, file) });
                    files.Add(file);
                }
                row["captures"] = files;
                return row;
            }
            finally
            {
                if (generated != null) Object.DestroyImmediate(generated);
                Object.DestroyImmediate(root);
            }
        }

        private static JArray MatrixRows(Matrix4x4 matrix) => new JArray(Enumerable.Range(0, 4)
            .Select(row => new JArray(Enumerable.Range(0, 4).Select(column => matrix[row, column]))));
    }
}
#endif
