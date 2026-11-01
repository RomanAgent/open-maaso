using System;
using System.Collections.Generic;
using UnityEngine;
using Maaso.World;

namespace Maaso.Avatar
{
    public interface IAvatarFurnitureRootDriver
    {
        bool IsValid { get; }
        Vector3 Position { get; }
        Quaternion Rotation { get; }
        bool TrySetPose(Vector3 position,Quaternion rotation);
    }
    /// <summary>Continuous, lower-body furniture pose owned by an admitted
    /// semantic action. Upper-body gestures and TTS remain independent.</summary>
    public sealed class AvatarFurniturePoseController
    {
        public const float ApproachWalkingSpeedMetersPerSecond = .85f * WorldLocomotionPresentation.DefaultWalkingSpeedMultiplier;
        public string Phase { get; private set; } = "standing";
        public string FurnitureId => anchor?.Id ?? string.Empty;
        public string WorkSessionId { get; private set; }
        public AvatarFurnitureAnchor WorkAnchor => WorkSessionId!=null && Phase=="working" ? anchor : null;
        public AvatarFurnitureAnchor DisplayWorkAnchor => work && Phase=="working" ? anchor : null;
        public bool IsReturningFromWork => returnWorkRequested;
        public string SceneId => rig != null ? rig.SceneId : "unbound";
        public bool Active => actor != null;
        public bool IsTransitioning => Phase == "approaching" || Phase == "aligning" || Phase == "rising";
        public bool IsLying => Phase == "lying";
        public bool PreserveUpperBodyGesture { get; set; }
        public Action<Transform,Animator> SynchronizeContactPose { get; set; }
        private Transform spine;
        private Quaternion spineNeutral;
        private Transform leftArm, leftElbow, leftHand, rightArm, rightElbow, rightHand;
        private Quaternion? leftHandBasis,rightHandBasis;
        private readonly Dictionary<Transform,Quaternion> typingRest = new();
        private readonly Dictionary<Transform,Quaternion> typingApplied = new();
        private float poseClock;
        private float leftAnkleHeight, rightAnkleHeight;
        private float sitPelvisOffset=.11f,liePelvisOffset=.12f,leftLieFootAdjustment,rightLieFootAdjustment;
        private Transform actor, hips, leftUpper, leftLower, leftFoot, rightUpper, rightLower, rightFoot;
        private AvatarFurnitureRig rig;
        private AvatarFurnitureAnchor anchor;
        private readonly Dictionary<Transform, Quaternion> neutral = new();
        private Vector3 neutralHips, originPosition;
        private Quaternion originRotation;
        private float started, duration, blendFrom, poseBlend, lieFrom, lieBlend;
        private bool lie, work, risingFromLie;
        private readonly List<Vector3> path = new();
        private int waypoint;
        private Action<string> changed;
        private Action<bool> walking;
        private string queued;
        private Vector3 workOriginPosition;
        private Quaternion workOriginRotation;
        private bool hasWorkOrigin, returnWorkRequested, returningWork, returnFacing;
        private Quaternion returnFacingFrom;
        private float returnFacingStarted, returnFacingDuration;
        private Animator animator;
        private PersonalSpacePocketDoor waitingForDoor;
        private IAvatarFurnitureRootDriver externalRoot;
        private Vector3 RootPosition=>externalRoot!=null?externalRoot.Position:actor.position;
        private Quaternion RootRotation=>externalRoot!=null?externalRoot.Rotation:actor.rotation;
        private void SetRootPose(Vector3 position,Quaternion rotation)
        {
            if(externalRoot==null){actor.SetPositionAndRotation(position,rotation);return;}
            if(!externalRoot.IsValid||!externalRoot.TrySetPose(position,rotation))throw new InvalidOperationException("furniture_root_driver_rejected");
        }
        public static bool IsGesture(string gesture) => gesture == "sit_sofa" || gesture == "sit_chair" || gesture == "work_desk" || gesture == "lie_bed" || gesture == "sit_bed" || gesture == "stand_up";

        public bool Begin(string gesture, Transform root, Animator humanoid, AvatarFurnitureRig scene,
            float now, Action<string> onChanged, Action<bool> setWalking)
        {
            string previousSession=WorkSessionId;
            if(gesture=="stand_up" && previousSession!=null)return EndWorkSession(previousSession,now);
            bool accepted=BeginCore(gesture,root,humanoid,scene,now,onChanged,setWalking,null);
            if(accepted && previousSession!=null)
            {
                WorkSessionId=null;RestoreTypingFingers();onChanged?.Invoke(Phase);
            }
            return accepted;
        }
        public bool BeginWorkSession(string sessionId, Transform root, Animator humanoid, AvatarFurnitureRig scene,
            float now, Action<string> onChanged, Action<bool> setWalking)
        {
            if(!ValidWorkSession(sessionId))return false;
            if(Active)return WorkSessionId==sessionId && work;
            WorkSessionId=sessionId;
            bool accepted=BeginCore("work_desk",root,humanoid,scene,now,onChanged,setWalking,null);
            if(!accepted)WorkSessionId=null;
            else { workOriginPosition=root.position; workOriginRotation=root.rotation; hasWorkOrigin=true; }
            return accepted;
        }
        public bool EndWorkSession(string sessionId,float now)
        {
            if(!ValidWorkSession(sessionId)||WorkSessionId!=sessionId||!Active)return false;
            WorkSessionId=null;RestoreTypingFingers();returnWorkRequested=hasWorkOrigin;
            if(Phase=="approaching" && poseBlend<=.001f && returnWorkRequested)StartReturn(now);
            else StartRise(now);
            return true;
        }
        private static bool ValidWorkSession(string value)
        {
            if(value==null||value.Length!=64)return false;
            foreach(char c in value)if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return false;
            return true;
        }
        public bool BeginExternal(string gesture,Transform root,Animator humanoid,AvatarFurnitureRig scene,
            float now,Action<string> onChanged,IAvatarFurnitureRootDriver driver)=>driver!=null&&driver.IsValid&&BeginCore(gesture,root,humanoid,scene,now,onChanged,_=>{},driver);
        private bool BeginCore(string gesture,Transform root,Animator humanoid,AvatarFurnitureRig scene,
            float now,Action<string> onChanged,Action<bool> setWalking,IAvatarFurnitureRootDriver driver)
        {
            if (!IsGesture(gesture) || root == null || humanoid == null || !humanoid.isHuman || scene == null) return false;
            scene.EnsureDeskWorkLayout();
            if(Active&&externalRoot!=driver)return false;
            if (gesture == "stand_up")
            {
                if (!Active) return true;
                returnWorkRequested=work && hasWorkOrigin;
                if(Phase=="approaching" && poseBlend<=.001f && returnWorkRequested)StartReturn(now);
                else StartRise(now);
                return true;
            }
            string id = gesture == "sit_sofa" ? "sofa" : gesture == "sit_chair" ? "chair" : gesture == "work_desk" ? "desk" : "bed";
            var seat = scene.Find(id);
            if (seat?.Seat == null || seat.Approach == null || (gesture == "lie_bed" && !seat.CanLie)) return false;
            if (Active)
            {
                if (actor != root || rig != scene) return false;
                if (anchor == seat && !IsTransitioning)
                {
                    if (lie == (gesture == "lie_bed") && work == (gesture == "work_desk")) return true;
                    originPosition = RootPosition; originRotation = RootRotation;
                    bool previousLie=lie,previousWork=work;float previousLieFrom=lieFrom;
                    lieFrom = lieBlend; lie = gesture == "lie_bed"; work = gesture == "work_desk";
                    if(!CalibrateContacts()){lie=previousLie;work=previousWork;lieFrom=previousLieFrom;return false;}
                    blendFrom = poseBlend; started = now; duration = .9f; SetPhase("aligning"); return true;
                }
                if(externalRoot!=null)return false;
                queued = gesture;returnWorkRequested=false;
                if (Phase != "rising") StartRise(now);
                return true;
            }
            Transform Bone(HumanBodyBones b) => humanoid.GetBoneTransform(b);
            spine = Bone(HumanBodyBones.Spine); if (spine != null) spineNeutral = spine.localRotation;
            hips = Bone(HumanBodyBones.Hips); leftUpper = Bone(HumanBodyBones.LeftUpperLeg); leftLower = Bone(HumanBodyBones.LeftLowerLeg); leftFoot = Bone(HumanBodyBones.LeftFoot);
            rightUpper = Bone(HumanBodyBones.RightUpperLeg); rightLower = Bone(HumanBodyBones.RightLowerLeg); rightFoot = Bone(HumanBodyBones.RightFoot);
            if (hips == null || hips==root || leftUpper == null || leftLower == null || leftFoot == null || rightUpper == null || rightLower == null || rightFoot == null) return false;
            List<Vector3> reviewedPath=null;
            Vector3 initialPosition=driver!=null?driver.Position:root.position;
            if(driver!=null)
            {
                Vector3 offset=initialPosition-seat.Approach.position;offset.y=0;
                if(offset.magnitude>.05f)return false;
                reviewedPath=new List<Vector3>{initialPosition};
            }
            else if(scene.Navigation!=null && !scene.Navigation.TryBuildRoute(root.position,seat.Approach.position,seat.Waypoints,out reviewedPath)) return false;
            PersonalSpacePocketDoor transitDoor=null;
            if(driver==null&&reviewedPath!=null && scene.Navigation.CrossesBedroomPortal(root.position,reviewedPath))
            {
                transitDoor=scene.Navigation.BedroomDoor;
                if(transitDoor==null || !transitDoor.Ready) return false;
            }
            if (!scene.TryOccupy(root)) return false;
            if(transitDoor!=null && !transitDoor.RequestOpen()) {scene.Release(root);return false;}
            waitingForDoor=transitDoor;
            leftArm=Bone(HumanBodyBones.LeftUpperArm); leftElbow=Bone(HumanBodyBones.LeftLowerArm); leftHand=Bone(HumanBodyBones.LeftHand);
            rightArm=Bone(HumanBodyBones.RightUpperArm); rightElbow=Bone(HumanBodyBones.RightLowerArm); rightHand=Bone(HumanBodyBones.RightHand);
            leftHandBasis=HandBasis(humanoid,true);rightHandBasis=HandBasis(humanoid,false);
            CaptureTypingFingers(humanoid);
            leftAnkleHeight = Mathf.Clamp(leftFoot.position.y - root.position.y, .035f, .14f);
            rightAnkleHeight = Mathf.Clamp(rightFoot.position.y - root.position.y, .035f, .14f);
            actor = root; animator = humanoid; rig = scene; anchor = seat; changed = onChanged; walking = setWalking;
            externalRoot=driver;
            sitPelvisOffset=.11f;liePelvisOffset=.12f;leftLieFootAdjustment=rightLieFootAdjustment=0;
            neutralHips = hips.localPosition;
            neutral.Clear(); foreach (var bone in new[] { hips, leftUpper, leftLower, leftFoot, rightUpper, rightLower, rightFoot }) neutral[bone] = bone.localRotation;
            lie = gesture == "lie_bed"; work = gesture == "work_desk"; poseBlend = 0; lieFrom = 0; lieBlend = 0;
            path.Clear();
            // Every package owns an explicit route through clear floor space.
            if(reviewedPath!=null) path.AddRange(reviewedPath);
            else
            {
                if (seat.Waypoints != null) foreach (var point in seat.Waypoints) if (point != null) path.Add(point.position);
                path.Add(seat.Approach.position);
            }
            waypoint = 0; started = now; originPosition = RootPosition;
            if(!CalibrateContacts()){Reset(false);return false;}
            if(work) { workOriginPosition=RootPosition; workOriginRotation=RootRotation; hasWorkOrigin=true; }
            SetApproachWalking(waitingForDoor==null || waitingForDoor.IsOpen); SetPhase("approaching"); return true;
        }

        public void Advance(float now, float deltaTime)
        {
            poseClock=now;
            if (!Active) return;
            if (rig == null || !rig.gameObject.activeInHierarchy || anchor?.Seat == null) { Reset(); return; }
            if(returningWork) { AdvanceReturn(now,deltaTime); return; }
            if (Phase == "approaching")
            {
                if(waitingForDoor!=null)
                {
                    if(!waitingForDoor.Ready || !waitingForDoor.gameObject.activeInHierarchy) {Reset(false);return;}
                    if(!waitingForDoor.IsOpen)return;
                    waitingForDoor=null;SetApproachWalking(true);
                }
                Vector3 target = path[waypoint]; target.y = RootPosition.y;
                Vector3 offset = target - RootPosition;
                if (offset.sqrMagnitude > .0025f)
                {
                    if(externalRoot!=null)throw new InvalidOperationException("external_furniture_must_arrive_before_begin");
                    Quaternion approachRotation=Quaternion.RotateTowards(RootRotation,Quaternion.LookRotation(offset,Vector3.up),Mathf.Max(0,deltaTime)*220f);
                    Vector3 next=Vector3.MoveTowards(RootPosition,target,Mathf.Max(0,deltaTime)*ApproachWalkingSpeedMetersPerSecond);
                    if(rig.Navigation!=null && !rig.Navigation.SegmentIsClear(RootPosition,next)) {Reset(false);return;}
                    SetRootPose(next,approachRotation);
                    return;
                }
                if (++waypoint < path.Count) return;
                SetApproachWalking(false); originPosition = RootPosition; originRotation = RootRotation;
                started = now; duration = 1f; blendFrom = 0; SetPhase("aligning");
            }
            float t = Mathf.SmoothStep(0, 1, Mathf.Clamp01((now - started) / Mathf.Max(.01f, duration)));
            if (Phase == "rising")
            {
                poseBlend = Mathf.Lerp(blendFrom, 0, t);
                Vector3 target = anchor.Approach.position; target.y = originPosition.y;
                SetRootPose(Vector3.Lerp(originPosition,target,t),Quaternion.Slerp(originRotation,anchor.Approach.rotation,t));
                lieBlend = Mathf.Lerp(risingFromLie ? 1 : 0, 0, t);
                ApplyPose(poseBlend, risingFromLie);
                if (t >= 1)
                {
                    if(returnWorkRequested && queued==null) { StartReturn(now); return; }
                    var next = queued; var root = actor; var model = animator; var scene = rig; var callback = changed; var walk = walking;
                    Reset(false); queued = null;
                    if (!string.IsNullOrEmpty(next)) Begin(next, root, model, scene, now, callback, walk);
                }
                return;
            }
            poseBlend = Phase == "aligning" ? Mathf.Lerp(blendFrom, 1, t) : 1;
            Transform targetAnchor = lie && anchor.Lying != null ? anchor.Lying : anchor.Seat;
            Vector3 destination = targetAnchor.position; destination.y = originPosition.y;
            Quaternion rotation = targetAnchor.rotation * (lie ? Quaternion.Euler(-90, 0, 0) : Quaternion.identity);
            lieBlend = Mathf.Lerp(lieFrom, lie ? 1 : 0, t);
            SetRootPose(Vector3.Lerp(originPosition,destination,t),Quaternion.Slerp(originRotation,rotation,t));
            ApplyPose(poseBlend, lie);
            if (Phase == "aligning" && t >= 1) SetPhase(lie ? "lying" : work ? "working" : "seated");
        }

        private void ApplyPose(float weight, bool lying)
        {
            if (hips == null || anchor?.Seat == null) return;
            foreach (var pair in neutral) if (pair.Key != null) pair.Key.localRotation = Quaternion.Slerp(pair.Key.localRotation, pair.Value, weight);
            hips.localPosition = Vector3.Lerp(hips.localPosition, neutralHips, weight);
            Vector3 sitPelvis = anchor.Seat.position + Vector3.up * sitPelvisOffset;
            if(work && rig.HasDeskKeyboard)sitPelvis+=anchor.Seat.forward*.045f;
            Vector3 liePelvis = (anchor.Lying != null ? anchor.Lying.position : anchor.Seat.position) + Vector3.up * liePelvisOffset;
            Vector3 pelvis = Vector3.Lerp(sitPelvis, liePelvis, lieBlend);
            hips.position = Vector3.Lerp(hips.position, pelvis, weight);
            Vector3 forward = anchor.Seat.forward, right = anchor.Seat.right;
            if (lieBlend > 0)
            {
                Vector3 alongBed = (anchor.Lying != null ? anchor.Lying.forward : forward);
                LieLeg(leftUpper,leftLower,leftFoot,alongBed,weight * lieBlend,leftLieFootAdjustment);
                LieLeg(rightUpper,rightLower,rightFoot,alongBed,weight * lieBlend,rightLieFootAdjustment);
            }
            if (lieBlend < 1)
            {
                SitLeg(leftUpper,leftLower,leftFoot,forward,leftAnkleHeight,weight * (1f-lieBlend));
                SitLeg(rightUpper,rightLower,rightFoot,forward,rightAnkleHeight,weight * (1f-lieBlend));
            }
            if (work && spine != null)
                spine.localRotation = spineNeutral * Quaternion.AngleAxis((rig.HasDeskKeyboard?22f:12f) * weight,
                    spine.InverseTransformDirection(right));
            if (!PreserveUpperBodyGesture && lieBlend < .5f)
            {
                float thighLength=(Vector3.Distance(leftUpper.position,leftLower.position)+Vector3.Distance(rightUpper.position,rightLower.position))*.5f;
                Vector3 center = work && anchor.WorkSurface != null ? anchor.WorkSurface.position :
                    anchor.Seat.position + Vector3.up * .18f + forward * (thighLength * .55f);
                bool typing=work && Phase=="working" && WorkSessionId!=null;
                float handSpread=work && rig.HasDeskKeyboard ? .085f : .17f;
                if(work&&rig.HasDeskKeyboard)center-=forward*.08f;
                PlaceHand(leftArm,leftElbow,leftHand,center-right*handSpread+TypingOffset(poseClock,true,typing),-right+Vector3.down*.4f,forward,leftHandBasis,work,weight);
                PlaceHand(rightArm,rightElbow,rightHand,center+right*handSpread+TypingOffset(poseClock,false,typing),right+Vector3.down*.4f,forward,rightHandBasis,work,weight);
                if(typing)ApplyTypingFingers(poseClock,weight);
            }
        }

        private Vector3 TypingOffset(float now,bool left,bool active)
        {
            if(!active)return Vector3.zero;
            float phase=now*18f+(left?0:Mathf.PI);
            float lift=(Mathf.Sin(phase)+1f)*.006f;
            return Vector3.up*lift+anchor.Seat.forward*(Mathf.Cos(phase*.57f)*.018f);
        }
        private void CaptureTypingFingers(Animator model)
        {
            typingRest.Clear();
            foreach(bool left in new[]{true,false})
            {
                HumanBodyBones[] bones=left?new[]{HumanBodyBones.LeftIndexProximal,HumanBodyBones.LeftMiddleProximal,HumanBodyBones.LeftRingProximal}:
                    new[]{HumanBodyBones.RightIndexProximal,HumanBodyBones.RightMiddleProximal,HumanBodyBones.RightRingProximal};
                string[] suffixes={"Index1","Mid1","Ring1"};
                Transform hand=model.GetBoneTransform(left?HumanBodyBones.LeftHand:HumanBodyBones.RightHand);
                for(int i=0;i<bones.Length;i++)
                {
                    Transform bone=model.GetBoneTransform(bones[i]);
                    if(bone==null && hand!=null)foreach(var child in hand.GetComponentsInChildren<Transform>())
                        if(child.name=="CC_Base_"+(left?"L_":"R_")+suffixes[i]){bone=child;break;}
                    if(bone!=null)typingRest[bone]=bone.localRotation;
                }
            }
        }
        private void ApplyTypingFingers(float now,float weight)
        {
            int index=0;
            foreach(var pair in typingRest)
            {
                if(pair.Key==null)continue;
                float beat=(Mathf.Sin(now*18f+index*1.35f)+1f)*.5f;
                Vector3 curlAxis=pair.Key.parent.InverseTransformDirection(anchor.Seat.right);
                pair.Key.localRotation=Quaternion.AngleAxis(beat*12f*weight,curlAxis)*pair.Value;
                typingApplied[pair.Key]=pair.Key.localRotation;
                index++;
            }
        }
        private void RestoreTypingFingers()
        {
            foreach(var pair in typingApplied)
                if(pair.Key!=null && Quaternion.Angle(pair.Key.localRotation,pair.Value)<.02f &&
                    typingRest.TryGetValue(pair.Key,out Quaternion rest))pair.Key.localRotation=rest;
            typingApplied.Clear();
        }

        private bool CalibrateContacts()
        {
            if(!anchor.HasMeasuredSupport)return true;
            // A bounded synchronous pose probe before the first visible frame.
            // Restore every transform in finally; no frame, physics step or
            // callback observes the probe. Skin baking never runs per frame.
            var saved=new List<(Transform bone,Vector3 position,Quaternion rotation)>();
            foreach(var bone in actor.GetComponentsInChildren<Transform>(true))
                if(externalRoot==null||bone!=actor)saved.Add((bone,bone.localPosition,bone.localRotation));
            float previousBlend=lieBlend;
            Vector3 savedRootPosition=RootPosition;Quaternion savedRootRotation=RootRotation;
            var previousProfile=(sitPelvisOffset,liePelvisOffset,leftLieFootAdjustment,rightLieFootAdjustment,leftAnkleHeight,rightAnkleHeight);
            bool calibrated=false;
            try
            {
                var target=lie?anchor.Lying:anchor.Seat;
                SetRootPose(new Vector3(target.position.x,savedRootPosition.y,target.position.z),target.rotation*(lie?Quaternion.Euler(-90,0,0):Quaternion.identity));
                lieBlend=lie?1:0;ApplyPose(1,lie);
                var vertices=BakeContactVertices();
                float pelvis=ContactMinimum(vertices,hips.position,.16f,true,Vector3.zero);
                float support=lie?anchor.LyingSupportY:anchor.SeatSupportY;
                if(float.IsInfinity(pelvis)||Mathf.Abs(support-pelvis)>.25f)return false;
                if(lie)liePelvisOffset+=support-pelvis;else sitPelvisOffset+=support-pelvis;
                ApplyPose(1,lie);vertices=BakeContactVertices();
                float left=ContactMinimum(vertices,leftFoot.position,.3f,false,rightFoot.position),right=ContactMinimum(vertices,rightFoot.position,.3f,false,leftFoot.position);
                support=lie?anchor.LyingSupportY:anchor.FootFloorY;
                if(float.IsInfinity(left)||float.IsInfinity(right)||Mathf.Abs(support-left)>.25f||Mathf.Abs(support-right)>.25f)return false;
                if(lie){leftLieFootAdjustment+=support-left;rightLieFootAdjustment+=support-right;}
                else{leftAnkleHeight+=support-left;rightAnkleHeight+=support-right;}
                if(externalRoot!=null&&rig.SceneKey=="coastal_v4"&&anchor.Id=="bed"&&!lie)
                {
                    // Solving ankle contact changes the upper-leg skin near the
                    // seated pelvis. Re-observe that coupled pose before a V4
                    // World admission, with a bounded correction budget. Home
                    // and other furniture keep their existing calibration.
                    for(int pass=0;pass<3;pass++)
                    {
                        ApplyPose(1,false);vertices=BakeContactVertices();
                        pelvis=ContactMinimum(vertices,hips.position,.16f,true,Vector3.zero);
                        left=ContactMinimum(vertices,leftFoot.position,.3f,false,rightFoot.position);
                        right=ContactMinimum(vertices,rightFoot.position,.3f,false,leftFoot.position);
                        float pelvisError=anchor.SeatSupportY-pelvis;
                        float leftError=anchor.FootFloorY-left,rightError=anchor.FootFloorY-right;
                        if(float.IsInfinity(pelvis)||float.IsInfinity(left)||float.IsInfinity(right)||
                            Mathf.Abs(pelvisError)>.05f||Mathf.Abs(leftError)>.05f||Mathf.Abs(rightError)>.05f)return false;
                        if(Mathf.Abs(pelvisError)<.001f&&Mathf.Abs(leftError)<.001f&&Mathf.Abs(rightError)<.001f)break;
                        sitPelvisOffset+=pelvisError;leftAnkleHeight+=leftError;rightAnkleHeight+=rightError;
                    }
                }
                calibrated=true;return true;
            }
            finally
            {
                if(externalRoot!=null&&externalRoot.IsValid)SetRootPose(savedRootPosition,savedRootRotation);
                foreach(var value in saved)if(value.bone!=null){value.bone.localPosition=value.position;value.bone.localRotation=value.rotation;}
                lieBlend=previousBlend;
                if(!calibrated)(sitPelvisOffset,liePelvisOffset,leftLieFootAdjustment,rightLieFootAdjustment,leftAnkleHeight,rightAnkleHeight)=previousProfile;
            }
        }
        private List<Vector3> BakeContactVertices()
        {
            SynchronizeContactPose?.Invoke(actor,animator);
            var vertices=new List<Vector3>();
            foreach(var skin in actor.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                if(!skin.enabled||skin.sharedMesh==null||!skin.gameObject.activeInHierarchy)continue;
                var mesh=new Mesh();
                try{skin.BakeMesh(mesh);foreach(var point in mesh.vertices)vertices.Add(skin.transform.TransformPoint(point));}
                finally{if(Application.isPlaying)UnityEngine.Object.Destroy(mesh);else UnityEngine.Object.DestroyImmediate(mesh);}
            }
            return vertices;
        }
        private float ContactMinimum(List<Vector3> vertices,Vector3 center,float radius,bool pelvis,Vector3 other)
        {
            float minimum=float.PositiveInfinity;
            foreach(var vertex in vertices)
            {
                Vector3 offset=vertex-center;
                float distance=offset.x*offset.x+offset.z*offset.z;
                if(distance>radius*radius||vertex.y>center.y+.2f)continue;
                if(pelvis){if(!lie&&Vector3.Dot(offset,anchor.Seat.forward)>.025f)continue;}
                else{Vector3 otherOffset=vertex-other;if(distance>otherOffset.x*otherOffset.x+otherOffset.z*otherOffset.z)continue;}
                minimum=Mathf.Min(minimum,vertex.y);
            }
            return minimum;
        }

        private static Quaternion? HandBasis(Animator model,bool left)
        {
            Transform hand=model.GetBoneTransform(left?HumanBodyBones.LeftHand:HumanBodyBones.RightHand);
            Transform Finger(HumanBodyBones bone,string suffix)
            {
                var mapped=model.GetBoneTransform(bone);if(mapped!=null)return mapped;
                // The reviewed CC Matt humanoid leaves optional finger mappings
                // empty but retains the original anatomical bones under Hand.
                if(hand!=null)foreach(var child in hand.GetComponentsInChildren<Transform>())
                    if(child.name=="CC_Base_"+(left?"L_":"R_")+suffix)return child;
                return null;
            }
            Transform middle=Finger(left?HumanBodyBones.LeftMiddleProximal:HumanBodyBones.RightMiddleProximal,"Mid1");
            Transform index=Finger(left?HumanBodyBones.LeftIndexProximal:HumanBodyBones.RightIndexProximal,"Index1");
            Transform little=Finger(left?HumanBodyBones.LeftLittleProximal:HumanBodyBones.RightLittleProximal,"Pinky1");
            if(hand==null||middle==null||index==null||little==null)return null;
            Vector3 fingers=hand.InverseTransformDirection(middle.position-hand.position).normalized;
            Vector3 across=hand.InverseTransformDirection(little.position-index.position).normalized;
            Vector3 dorsal=Vector3.Cross(across,fingers)*(left?1:-1);
            return dorsal.sqrMagnitude>.0001f?Quaternion.LookRotation(fingers,dorsal):null;
        }
        private static void PlaceHand(Transform upper,Transform lower,Transform hand,Vector3 target,Vector3 bend,Vector3 forward,Quaternion? basis,bool onDesk,float weight)
        {
            if(upper==null||lower==null||hand==null)return;
            if(onDesk)
            {
                target.y+=.025f;
                // Keep wrist contact at tabletop height even when the authored
                // keyboard centre is beyond this avatar's arm reach.
                float reach=(Vector3.Distance(upper.position,lower.position)+Vector3.Distance(lower.position,hand.position))*.97f;
                float dy=target.y-upper.position.y;
                float horizontal=Mathf.Sqrt(Mathf.Max(0,reach*reach-dy*dy));
                Vector3 delta=target-upper.position;delta.y=0;
                if(delta.magnitude>horizontal){delta=delta.normalized*horizontal;target.x=upper.position.x+delta.x;target.z=upper.position.z+delta.z;}
            }
            Reach(upper,lower,hand,target,bend,weight);
            if(basis.HasValue)hand.rotation=Quaternion.Slerp(hand.rotation,Quaternion.LookRotation(forward,Vector3.up)*Quaternion.Inverse(basis.Value),weight);
        }

        private static void SitLeg(Transform upper,Transform lower,Transform foot,Vector3 forward,float ankleHeight,float weight)
        {
            float thigh=Vector3.Distance(upper.position,lower.position);
            Vector3 target=upper.position+forward*(thigh*.92f);
            target.y=ankleHeight;
            Reach(upper,lower,foot,target,forward,weight);
        }
        private static void LieLeg(Transform upper,Transform lower,Transform foot,Vector3 direction,float weight,float adjustment)
        {
            float length=Vector3.Distance(upper.position,lower.position)+Vector3.Distance(lower.position,foot.position);
            Vector3 target=upper.position+direction*(length*.99f)+Vector3.up*(-.045f+adjustment);
            Reach(upper,lower,foot,target,Vector3.up,weight);
        }
        private static void Reach(Transform upper,Transform lower,Transform end,Vector3 target,Vector3 bendHint,float weight)
        {
            if(upper==null || lower==null || end==null || weight<=0) return;
            float a=Vector3.Distance(upper.position,lower.position),b=Vector3.Distance(lower.position,end.position);
            Vector3 offset=target-upper.position;
            float distance=Mathf.Clamp(offset.magnitude,Mathf.Abs(a-b)+.001f,a+b-.001f);
            Vector3 axis=offset.normalized;
            Vector3 bend=(bendHint-axis*Vector3.Dot(bendHint,axis)).normalized;
            if(bend.sqrMagnitude<.001f) bend=Vector3.Cross(axis,Vector3.right).normalized;
            float along=(a*a-b*b+distance*distance)/(2*distance);
            Vector3 joint=upper.position+axis*along+bend*Mathf.Sqrt(Mathf.Max(0,a*a-along*along));
            Quaternion endRotation=end.rotation;
            upper.rotation=Quaternion.Slerp(upper.rotation,Quaternion.FromToRotation(lower.position-upper.position,joint-upper.position)*upper.rotation,weight);
            lower.rotation=Quaternion.Slerp(lower.rotation,Quaternion.FromToRotation(end.position-lower.position,target-lower.position)*lower.rotation,weight);
            end.rotation=Quaternion.Slerp(end.rotation,endRotation,weight);
        }

        private void StartRise(float now)
        {
            originPosition = RootPosition; originRotation = RootRotation; risingFromLie = lie;
            started = now; duration = 1.1f; blendFrom = poseBlend; SetApproachWalking(false); SetPhase("rising");
        }
        private void StartReturn(float now)
        {
            returningWork=true;returnFacing=false;poseBlend=0;lieBlend=0;work=false;
            foreach(var pose in neutral)if(pose.Key!=null)pose.Key.localRotation=pose.Value;
            if(spine!=null)spine.localRotation=spineNeutral;
            if(hips!=null)hips.localPosition=neutralHips;
            path.Clear();waypoint=0;waitingForDoor=null;
            if(rig.Navigation!=null)
            {
                if(!rig.Navigation.TryBuildRoute(RootPosition,workOriginPosition,null,out var route)) { Reset(false); return; }
                path.AddRange(route);
                if(rig.Navigation.CrossesBedroomPortal(RootPosition,path))
                {
                    waitingForDoor=rig.Navigation.BedroomDoor;
                    if(waitingForDoor==null||!waitingForDoor.Ready||!waitingForDoor.RequestOpen()) { Reset(false); return; }
                }
            }
            else path.Add(workOriginPosition);
            SetPhase("rising");SetApproachWalking(waitingForDoor==null||waitingForDoor.IsOpen);
        }
        private void AdvanceReturn(float now,float deltaTime)
        {
            float delta=Mathf.Max(0,deltaTime);
            if(waitingForDoor!=null)
            {
                if(!waitingForDoor.Ready) { Reset(false); return; }
                if(!waitingForDoor.IsOpen)return;
                waitingForDoor=null;SetApproachWalking(true);
            }
            if(!returnFacing)
            {
                float distance=WorldLocomotionPresentation.WalkingSpeedMetersPerSecond*delta;
                while(waypoint<path.Count)
                {
                    Vector3 destination=path[waypoint];destination.y=workOriginPosition.y;
                    Vector3 offset=destination-RootPosition;
                    if(offset.magnitude<.001f) { waypoint++;continue; }
                    Vector3 next=Vector3.MoveTowards(RootPosition,destination,distance);
                    if(rig.Navigation!=null&&!rig.Navigation.SegmentIsClear(RootPosition,next)) { Reset(false);return; }
                    Quaternion facing=Quaternion.RotateTowards(RootRotation,Quaternion.LookRotation(offset,Vector3.up),delta*220f);
                    float moved=Vector3.Distance(RootPosition,next);SetRootPose(next,facing);distance-=moved;
                    if(Vector3.Distance(next,destination)<.001f)waypoint++;
                    if(distance<=.0001f)break;
                }
                if(waypoint<path.Count)return;
                SetApproachWalking(false);returnFacing=true;returnFacingFrom=RootRotation;returnFacingStarted=now;
                returnFacingDuration=Mathf.Max(.35f,Quaternion.Angle(returnFacingFrom,workOriginRotation)/180f);
            }
            float t=Mathf.SmoothStep(0,1,Mathf.Clamp01((now-returnFacingStarted)/returnFacingDuration));
            SetRootPose(workOriginPosition,Quaternion.Slerp(returnFacingFrom,workOriginRotation,t));
            if(t>=1)Reset(false);
        }
        private void SetPhase(string value) { Phase = value; changed?.Invoke(value); }

        public void ResetWorkToOrigin()
        {
            // Terminal host-task cancellation must restore the saved Home
            // root before releasing the seated bones. Reset(false) alone
            // leaves a standing actor inside the desk chair.
            if (Active && hasWorkOrigin && externalRoot == null)
                SetRootPose(workOriginPosition, workOriginRotation);
            Reset(false);
        }

        public void Reset(bool restorePosition = true)
        {
            WorkSessionId=null;RestoreTypingFingers();
            if (actor != null)
            {
                SetApproachWalking(false);
                foreach (var p in neutral) if (p.Key != null) p.Key.localRotation = p.Value;
                if(spine!=null)spine.localRotation=spineNeutral;
                if (hips != null) hips.localPosition = neutralHips;
                if (restorePosition && anchor?.Approach != null)SetRootPose(new Vector3(anchor.Approach.position.x,RootPosition.y,anchor.Approach.position.z),anchor.Approach.rotation);
                rig?.Release(actor); SetPhase("standing");
            }
            actor = null; rig = null; anchor = null; externalRoot=null;waitingForDoor=null; neutral.Clear(); queued = null; poseBlend = 0; Phase = "standing";
            hasWorkOrigin=returnWorkRequested=returningWork=returnFacing=false;
            typingRest.Clear();
        }
        private void SetApproachWalking(bool active)
        {
            walking?.Invoke(active);
            // The receiver callback starts the walk first. Its generic gait
            // calibration must then match this slower furniture approach.
            WorldLocomotionPresentation.ApplyWalkingAnimationSpeed(animator, active,
                returningWork?WorldLocomotionPresentation.WalkingSpeedMetersPerSecond:ApproachWalkingSpeedMetersPerSecond);
        }
    }
}
