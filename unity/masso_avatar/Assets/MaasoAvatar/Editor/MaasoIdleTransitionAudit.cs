#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UniVRM10;
using UnityEditor;
using UnityEditor.Animations;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>Disposable continuous-pose A/B diagnostic. Never saves controller, scene or model assets.</summary>
    public static class MaasoIdleTransitionAudit
    {
        private const string ControllerPath = "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";
        private static readonly HumanBodyBones[] Bones = { HumanBodyBones.Hips, HumanBodyBones.LeftUpperLeg,
            HumanBodyBones.LeftLowerLeg, HumanBodyBones.LeftFoot, HumanBodyBones.RightUpperLeg,
            HumanBodyBones.RightLowerLeg, HumanBodyBones.RightFoot };
        private static readonly (int frame, string state, float fade)[] Events = {
            (60, "annie_idle_c", .12f), (180, "idle_shrug", .2f),
            (240, "annie_listen_b", .12f), (360, "idle_shrug", .2f),
            (420, "annie_fidget_hips", .12f), (540, "idle_shrug", .2f) };

        public static void Run()
        {
            string[] args = Environment.GetCommandLineArgs();
            int option = Array.IndexOf(args, "-maasoIdleTransitionOutput");
            string output = option >= 0 ? args[option + 1] : "/private/tmp/maaso-idle-transition-20261015";
            Directory.CreateDirectory(output);
            AnimatorController source = AssetDatabase.LoadAssetAtPath<AnimatorController>(ControllerPath);
            if (source == null) throw new InvalidOperationException("Missing actual controller");
            var a = Capture(source, output, "A-authored-foot-ik");
            var disposable = new List<Object>();
            try
            {
                AnimatorController noFootIk = CloneController(source, disposable);
                var b = Capture(noFootIk, output, "B-memory-no-foot-ik");
                File.WriteAllText(Path.Combine(output, "receipt.json"), new JObject {
                    ["scope"] = "Actual Joy Animator and VRM Process, 60fps continuous frames; no Receiver, gait edits, source asset mutation or saves.",
                    ["events"] = new JArray(Events.Select(e => new JObject { ["frame"] = e.frame, ["state"] = e.state, ["fadeSeconds"] = e.fade })),
                    ["A"] = a, ["B"] = b,
                    ["flagsEliminatedWithoutFootIk"] = (int)a["flaggedFrames"] > 0 && (int)b["flaggedFrames"] == 0,
                }.ToString());
            }
            finally { for (int i = disposable.Count - 1; i >= 0; i--) Object.DestroyImmediate(disposable[i]); }
            Debug.Log("[MaasoIdleTransitionAudit] Wrote " + output);
        }

        private static JObject Capture(AnimatorController controller, string output, string label)
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            GameObject root = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            root.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            var vrm = root.GetComponent<Vrm10Instance>(); vrm.enabled = false;
            Animator animator = root.GetComponentInChildren<Animator>();
            animator.cullingMode = AnimatorCullingMode.AlwaysAnimate; animator.applyRootMotion = false;
            animator.runtimeAnimatorController = controller; _ = vrm.Runtime;
            animator.Rebind(); animator.Play("Base Layer.idle_shrug", 0, 0f); animator.Update(0f); vrm.Runtime.Process();
            var bones = Bones.ToDictionary(id => id, id => vrm.Humanoid.GetBoneTransform(id));
            Vector3 hip = bones[HumanBodyBones.Hips].position;
            float leftY = bones[HumanBodyBones.LeftFoot].position.y, rightY = bones[HumanBodyBones.RightFoot].position.y;
            var timeline = new JArray(); int flagged = 0, maximumFrame = 0; float maximumRise = float.NegativeInfinity;
            Transform[] all = root.GetComponentsInChildren<Transform>(true);
            Vector3[] worstPositions = null; Quaternion[] worstRotations = null;
            try
            {
                for (int frame = 0; frame < 660; frame++)
                {
                    foreach (var e in Events) if (frame == e.frame)
                        animator.CrossFadeInFixedTime("Base Layer." + e.state, e.fade, 0, 0f);
                    animator.Update(1f / 60f); vrm.Runtime.Process();
                    // Settled authored idle establishes the reference, excluding initial retarget warmup.
                    if (frame == 59) { hip = bones[HumanBodyBones.Hips].position; leftY = bones[HumanBodyBones.LeftFoot].position.y; rightY = bones[HumanBodyBones.RightFoot].position.y; }
                    float hipDelta = Vector3.Distance(bones[HumanBodyBones.Hips].position, hip);
                    float rise = Mathf.Max(bones[HumanBodyBones.LeftFoot].position.y - leftY, bones[HumanBodyBones.RightFoot].position.y - rightY);
                    bool flag = frame >= 60 && rise > .18f && hipDelta < .1f;
                    if (flag) flagged++;
                    if (frame >= 60 && rise > maximumRise)
                    {
                        maximumRise = rise; maximumFrame = frame;
                        worstPositions = all.Select(t => t.localPosition).ToArray();
                        worstRotations = all.Select(t => t.localRotation).ToArray();
                    }
                    var state = animator.GetCurrentAnimatorStateInfo(0); var next = animator.GetNextAnimatorStateInfo(0);
                    var row = new JObject { ["frame"] = frame, ["time"] = frame / 60f, ["stateHash"] = state.shortNameHash,
                        ["normalizedTime"] = state.normalizedTime, ["transition"] = animator.IsInTransition(0), ["nextStateHash"] = next.shortNameHash,
                        ["ankleRise"] = rise, ["hipDelta"] = hipDelta, ["flag"] = flag, ["bones"] = new JObject() };
                    foreach (var bone in bones) ((JObject)row["bones"])[bone.Key.ToString()] = JArray.FromObject(new[] { bone.Value.position.x, bone.Value.position.y, bone.Value.position.z });
                    timeline.Add(row);
                }
                File.WriteAllText(Path.Combine(output, label + "-timeline.json"), timeline.ToString());
                string image = null;
                if (worstPositions != null && SystemInfo.graphicsDeviceType != UnityEngine.Rendering.GraphicsDeviceType.Null)
                {
                    for (int i = 0; i < all.Length; i++) { all[i].localPosition = worstPositions[i]; all[i].localRotation = worstRotations[i]; }
                    const BindingFlags flags = BindingFlags.NonPublic | BindingFlags.Static;
                    var type = typeof(MaasoSpeechPerformanceReplay);
                    Camera camera = (Camera)type.GetMethod("CreateCamera", flags).Invoke(null, new object[] { root });
                    image = Path.Combine(output, label + "-worst.png");
                    type.GetMethod("Render", flags).Invoke(null, new object[] { camera, root, image });
                }
                return new JObject { ["label"] = label, ["frames"] = timeline.Count, ["flaggedFrames"] = flagged,
                    ["maximumAnkleRiseMeters"] = maximumRise, ["maximumFrame"] = maximumFrame, ["worstImage"] = image };
            }
            finally { Object.DestroyImmediate(root); EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single); }
        }

        private static AnimatorController CloneController(AnimatorController source, List<Object> disposable)
        {
            T Clone<T>(T value) where T : Object { T copy = Object.Instantiate(value); copy.hideFlags = HideFlags.HideAndDontSave; disposable.Add(copy); return copy; }
            var machines = new Dictionary<AnimatorStateMachine, AnimatorStateMachine>();
            var states = new Dictionary<AnimatorState, AnimatorState>();
            AnimatorStateMachine CopyMachine(AnimatorStateMachine original)
            {
                if (machines.TryGetValue(original, out var prior)) return prior;
                var copy = Clone(original); machines.Add(original, copy);
                var children = original.states;
                for (int i = 0; i < children.Length; i++) { var state = Clone(children[i].state); states.Add(children[i].state, state); state.iKOnFeet = false; children[i].state = state; }
                copy.states = children;
                var nested = original.stateMachines;
                for (int i = 0; i < nested.Length; i++) nested[i].stateMachine = CopyMachine(nested[i].stateMachine);
                copy.stateMachines = nested;
                return copy;
            }
            var result = Clone(source); var layers = result.layers;
            for (int i = 0; i < layers.Length; i++) layers[i].stateMachine = CopyMachine(source.layers[i].stateMachine);
            AnimatorTransitionBase CopyTransition(AnimatorTransitionBase original)
            {
                var copy = Clone(original);
                copy.destinationState = original.destinationState != null ? states[original.destinationState] : null;
                copy.destinationStateMachine = original.destinationStateMachine != null ? machines[original.destinationStateMachine] : null;
                return copy;
            }
            foreach (var pair in states) pair.Value.transitions = pair.Key.transitions.Select(t => (AnimatorStateTransition)CopyTransition(t)).ToArray();
            foreach (var pair in machines)
            {
                pair.Value.defaultState = pair.Key.defaultState != null ? states[pair.Key.defaultState] : null;
                pair.Value.anyStateTransitions = pair.Key.anyStateTransitions.Select(t => (AnimatorStateTransition)CopyTransition(t)).ToArray();
                pair.Value.entryTransitions = pair.Key.entryTransitions.Select(t => (AnimatorTransition)CopyTransition(t)).ToArray();
                foreach (var child in pair.Key.stateMachines)
                    pair.Value.SetStateMachineTransitions(machines[child.stateMachine], pair.Key.GetStateMachineTransitions(child.stateMachine).Select(t => (AnimatorTransition)CopyTransition(t)).ToArray());
            }
            result.layers = layers;
            return result;
        }
    }
}
#endif
