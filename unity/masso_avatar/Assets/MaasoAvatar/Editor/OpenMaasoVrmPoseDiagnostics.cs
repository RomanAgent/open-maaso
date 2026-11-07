#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

namespace Maaso.Avatar.Editor
{
    public static class OpenMaasoVrmPoseDiagnostics
    {
        [Serializable] private sealed class Report { public Sample[] samples; public Muscle[] importedMuscles; }
        [Serializable] private sealed class Muscle { public string name; public float value; }
        [Serializable] private sealed class Sample
        {
            public string name;
            public Vector3 leftUpper, leftElbow, leftHand, rightUpper, rightElbow, rightHand;
            public float handSeparation, leftElbowDegrees, rightElbowDegrees;
        }

        public static void Run()
        {
            string output = Environment.GetEnvironmentVariable("OPEN_MAASO_POSE_DIAGNOSTIC");
            if (string.IsNullOrWhiteSpace(output)) throw new InvalidOperationException("Set OPEN_MAASO_POSE_DIAGNOSTIC.");
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            var source = AssetDatabase.LoadAssetAtPath<GameObject>(MaasoDefaultAvatarSceneBuilder.DefaultVrmPath);
            var root = UnityEngine.Object.Instantiate(source);
            var animator = root.GetComponentInChildren<Animator>();
            var vrm = root.GetComponentInChildren<Vrm10Instance>();
            var samples = new List<Sample>();
            HumanPose rest = new HumanPose();
            using (var handler = new HumanPoseHandler(animator.avatar, animator.transform))
            {
                handler.GetHumanPose(ref rest);
                var muscles = new Muscle[HumanTrait.MuscleCount];
                for (int i = 0; i < muscles.Length; i++) muscles[i] = new Muscle { name = HumanTrait.MuscleName[i], value = rest.muscles[i] };
                samples.Add(Measure("imported", animator));
                animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(MaasoDefaultAvatarSceneBuilder.ControllerPath);
                animator.Rebind(); animator.Update(0f); vrm.Runtime.Process();
                samples.Add(Measure("generated_idle", animator));
                animator.enabled = false;
                foreach (var preset in new[] { (down: -.75f, front: .30f), (down: -.75f, front: .15f), (down: -.70f, front: .15f), (down: -.75f, front: .10f) })
                {
                    var pose = new HumanPose { bodyPosition = rest.bodyPosition, bodyRotation = rest.bodyRotation, muscles = (float[])rest.muscles.Clone() };
                    for (int i = 0; i < HumanTrait.MuscleCount; i++)
                    {
                        if (HumanTrait.MuscleName[i] is "Left Arm Down-Up" or "Right Arm Down-Up") pose.muscles[i] = preset.down;
                        if (HumanTrait.MuscleName[i] is "Left Arm Front-Back" or "Right Arm Front-Back") pose.muscles[i] = preset.front;
                    }
                    handler.SetHumanPose(ref pose); vrm.Runtime.Process();
                    samples.Add(Measure("complete_down_" + preset.down + "_front_" + preset.front, animator));
                }
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output)));
                File.WriteAllText(output, JsonUtility.ToJson(new Report { samples = samples.ToArray(), importedMuscles = muscles }, true));
            }
            UnityEngine.Object.DestroyImmediate(root);
        }

        private static Sample Measure(string name, Animator animator)
        {
            Vector3 Bone(HumanBodyBones bone) => animator.GetBoneTransform(bone).position;
            Vector3 lu = Bone(HumanBodyBones.LeftUpperArm), le = Bone(HumanBodyBones.LeftLowerArm), lh = Bone(HumanBodyBones.LeftHand);
            Vector3 ru = Bone(HumanBodyBones.RightUpperArm), re = Bone(HumanBodyBones.RightLowerArm), rh = Bone(HumanBodyBones.RightHand);
            return new Sample { name = name, leftUpper = lu, leftElbow = le, leftHand = lh, rightUpper = ru, rightElbow = re, rightHand = rh,
                handSeparation = Vector3.Distance(lh, rh), leftElbowDegrees = Vector3.Angle(lu - le, lh - le), rightElbowDegrees = Vector3.Angle(ru - re, rh - re) };
        }
    }
}
#endif
