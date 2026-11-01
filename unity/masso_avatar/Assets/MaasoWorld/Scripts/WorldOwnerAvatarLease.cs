using Maaso.Avatar;
using UnityEngine;

namespace Maaso.World
{
    [DisallowMultipleComponent]
    public sealed class WorldOwnerAvatarLease : MonoBehaviour
    {
        private UnityAvatarCommandReceiver receiver;
        private Transform homeAnchor;
        private Transform groundedAvatar;
        private Vector3 targetPosition;
        private Quaternion targetRotation = Quaternion.identity;
        private bool bound;
        private bool returningHome;
        private Vector3 returnStartPosition;
        private Quaternion returnStartRotation = Quaternion.identity;
        private float returnStartedAt;
        private float returnDuration;
        private bool locomotionActive;
        private float locomotionElapsed;
        private float walkingPhaseBaseElapsed;
        private float walkingStepSeconds;
        private float targetArrivalElapsed;
        private Animator locomotionAnimator;
        private RuntimeAnimatorController locomotionController;
        private bool hasWalkingPhaseOrigin;
        private float walkingPhaseOrigin;
        private float lastWalkingPhase;
        private bool worldVisible = true;
        private Transform hiddenAvatar;
        private bool hiddenAvatarWasActive;
        private Quaternion personalVisualRotation = Quaternion.identity;
        private bool personalHomePresentation;
        private bool settleAtTarget = true;
        private float NavigationWalkingSpeed => WorldLocomotionPresentation.WalkingSpeedMetersPerSecond;
        private System.Func<bool> routeContinuation;
        private int routeContinuationDepth;

        public void SetRouteContinuation(System.Func<bool> continuation)
            => routeContinuation = bound && personalHomePresentation ? continuation : null;

        public bool IsBound => bound;
        public Transform AvatarRoot => receiver?.ActiveAvatarRoot;
        public bool IsWorldVisible => worldVisible;
        public bool IsMoving => locomotionActive;

        public bool FaceStationaryPersonalHome()
        {
            if (!bound || returningHome || locomotionActive || homeAnchor == null) return false;
            targetRotation = personalHomePresentation
                ? homeAnchor.rotation * Quaternion.Inverse(personalVisualRotation)
                : homeAnchor.rotation;
            return Quaternion.Angle(transform.rotation, targetRotation) < .1f;
        }
        /// <summary>The selected model inherits the local room visibility across replacements.</summary>
        public void SetWorldVisible(bool visible)
        {
            worldVisible = visible;
            Transform currentAvatar = AvatarRoot;
            if (hiddenAvatar != null && hiddenAvatar != currentAvatar)
            {
                // A model replacement retires the previous root. Restoring its
                // saved activeSelf state would resurrect the bundled avatar
                // after the receiver has switched to the new model.
                hiddenAvatar = null;
                hiddenAvatarWasActive = false;
            }
            if (visible)
            {
                if (hiddenAvatar != null) hiddenAvatar.gameObject.SetActive(hiddenAvatarWasActive);
                hiddenAvatar = null;
                return;
            }
            SetLocomotion(false);
            if (currentAvatar != hiddenAvatar)
            {
                hiddenAvatar = currentAvatar;
                hiddenAvatarWasActive = currentAvatar != null && currentAvatar.gameObject.activeSelf;
            }
            if (hiddenAvatar != null) hiddenAvatar.gameObject.SetActive(false);
        }

        public bool Bind(
            UnityAvatarCommandReceiver avatarReceiver,
            Transform agentHomeAnchor,
            Vector3 worldPosition,
            Quaternion worldRotation)
            => BindCore(avatarReceiver, agentHomeAnchor, worldPosition, worldRotation, false);

        public bool BindPersonalRoom(
            UnityAvatarCommandReceiver avatarReceiver,
            Transform agentHomeAnchor,
            Vector3 worldPosition,
            Quaternion worldRotation)
            => BindCore(avatarReceiver, agentHomeAnchor, worldPosition, worldRotation, true);

        private bool BindCore(
            UnityAvatarCommandReceiver avatarReceiver,
            Transform agentHomeAnchor,
            Vector3 worldPosition,
            Quaternion worldRotation,
            bool preserveHomePresentation)
        {
            if (avatarReceiver == null)
            {
                return false;
            }

            routeContinuation = null;
            receiver = avatarReceiver;
            homeAnchor = agentHomeAnchor;
            Transform selectedAvatar = receiver.ActiveAvatarRoot;
            Vector3 selectedPosition = selectedAvatar != null ? selectedAvatar.position : worldPosition;
            Quaternion selectedRotation = selectedAvatar != null ? selectedAvatar.rotation : worldRotation;
            Camera camera = Camera.main ?? FindAnyObjectByType<Camera>();
            float cameraAspect = camera != null ? camera.aspect : 9f / 16f;
            Quaternion entryRotation = preserveHomePresentation ? worldRotation :
                WorldCameraDirector.CalculateOwnerEntryRotation(
                    worldPosition,
                    cameraAspect,
                    worldRotation);
            ApplyTarget(worldPosition, entryRotation, true);
            if (!receiver.TryLeaseActiveAvatarForWorld(transform))
            {
                receiver = null;
                homeAnchor = null;
                return false;
            }

            bound = true;
            returningHome = false;
            personalHomePresentation = preserveHomePresentation;
            if (preserveHomePresentation && selectedAvatar != null && receiver.ActiveAvatarRoot == selectedAvatar)
            {
                // This room uses the same selected model already in Home. The
                // lease must not rotate or relocate that first visible image.
                // Keep the imported forward correction on the visual child;
                // the owner carries its logical physical-facing direction.
                personalVisualRotation = selectedAvatar.localRotation;
                transform.rotation = selectedRotation * Quaternion.Inverse(personalVisualRotation);
                targetRotation = transform.rotation;
                selectedAvatar.SetPositionAndRotation(selectedPosition, selectedRotation);
                receiver.RebaseActiveAvatarRootPose();
            }
            EnsureCurrentAvatarGrounded();
            receiver.SetWorldLocomotion(locomotionActive);
            return true;
        }

        public void ApplyTarget(
            Vector3 worldPosition,
            Quaternion worldRotation,
            bool immediate = false)
            => ApplyTargetCore(worldPosition, worldRotation, immediate, true);

        public void ApplyRouteTarget(Vector3 worldPosition, Quaternion worldRotation, bool finalDestination)
            => ApplyTargetCore(worldPosition, worldRotation, false, finalDestination);

        private void ApplyTargetCore(Vector3 worldPosition, Quaternion worldRotation, bool immediate, bool settle)
        {
            worldPosition =
                PersistentWorldMapController.ProjectToActiveGround(worldPosition);
            if (!immediate && settleAtTarget == settle && (worldPosition - targetPosition).sqrMagnitude < .000001f)
            {
                // Server snapshots and held touch input can repeat a target.
                // Keep the running stride clock and arrival time unchanged.
                return;
            }
            settleAtTarget = settle;
            targetPosition = worldPosition;
            Quaternion snapshotRotation = Quaternion.Euler(
                0f,
                worldRotation.eulerAngles.y,
                0f);
            targetRotation = immediate
                ? snapshotRotation
                : WorldLocomotionPresentation.ResolveFacing(
                    transform.position,
                    targetPosition,
                    targetRotation);
            Vector3 planarRemaining = targetPosition - transform.position; planarRemaining.y = 0f;
            bool needsMovement = !immediate && (settle
                ? WorldLocomotionPresentation.ShouldMove(transform.position, targetPosition, locomotionActive)
                : planarRemaining.sqrMagnitude > .000001f);
            if(personalHomePresentation && locomotionActive && !immediate)
                needsMovement=planarRemaining.sqrMagnitude>.000001f;
            // A changed nearby target can shorten a trip, but must not cut the
            // current foot swing. Exits and immediate placement still stop now.
            SetLocomotion(needsMovement || (!immediate && locomotionActive && walkingStepSeconds > 0f));
            if (locomotionActive && walkingStepSeconds > 0f)
            {
                Vector3 remaining = targetPosition - transform.position;
                remaining.y = 0f;
                targetArrivalElapsed = ArrivalElapsedForDistance(remaining.magnitude, locomotionElapsed);
                UpdateWalkingStride(remaining.magnitude);
            }
            if (immediate)
            {
                transform.SetPositionAndRotation(targetPosition, targetRotation);
            }
        }

        public void RefreshStationaryEntryFacing()
        {
            if (!bound || returningHome || WorldLocomotionPresentation.ShouldMove(
                    transform.position, targetPosition, locomotionActive))
            {
                return;
            }

            // A committed map can put its overview camera on the other side of
            // the owner. Change the destination once; LateUpdate keeps the
            // normal rotation transition and movement still owns its heading.
            Camera camera = Camera.main ?? FindAnyObjectByType<Camera>();
            targetRotation = WorldCameraDirector.CalculateOwnerEntryRotation(
                transform.position,
                camera != null ? camera.aspect : 9f / 16f,
                targetRotation);
        }

        public void BeginReturnToHome(float duration)
        {
            if (!bound)
            {
                return;
            }
            returnStartPosition = transform.position;
            returnStartRotation = transform.rotation;
            returnStartedAt = Time.realtimeSinceStartup;
            returnDuration = Mathf.Max(0f, duration);
            returningHome = true;
            if (returnDuration <= 0f)
            {
                CompleteReturnToHome();
            }
        }

        public void CompleteReturnToHome()
        {
            routeContinuation = null;
            SetWorldVisible(true);
            if (!bound)
            {
                SetLocomotion(false);
                return;
            }

            SetLocomotion(false);
            if (homeAnchor != null)
            {
                transform.SetPositionAndRotation(
                    homeAnchor.position,
                    homeAnchor.rotation);
            }
            receiver?.RestoreActiveAvatarFromWorld(homeAnchor);
            bound = false;
            returningHome = false;
            groundedAvatar = null;
            receiver = null;
            homeAnchor = null;
            personalHomePresentation = false;
            personalVisualRotation = Quaternion.identity;
        }

        public bool CompletePersonalReturnToHome()
        {
            if(!bound || !personalHomePresentation || returningHome || locomotionActive ||
                homeAnchor==null || receiver==null || AvatarRoot==null)return false;
            if(!receiver.RestoreActiveAvatarFromPersonalRoom(homeAnchor))return false;
            routeContinuation=null;bound=false;returningHome=false;groundedAvatar=null;
            receiver=null;homeAnchor=null;personalHomePresentation=false;personalVisualRotation=Quaternion.identity;
            return true;
        }

        private void LateUpdate()
        {
            if (!bound)
            {
                return;
            }
            if (!worldVisible && !returningHome)
            {
                // A late reviewed-model swap must inherit the hidden state.
                SetWorldVisible(false);
                return;
            }
            EnsureCurrentAvatarGrounded();
            if (returningHome)
            {
                UpdateReturnToHome();
                return;
            }

            AdvanceLocomotion(Time.unscaledDeltaTime);
        }

        private void AdvanceLocomotion(float unscaledDeltaTime)
        {
            float delta = Mathf.Max(0f, unscaledDeltaTime);
            if (locomotionActive)
            {
                Animator currentAnimator = AvatarRoot?.GetComponentInChildren<Animator>(true);
                if (currentAnimator != locomotionAnimator ||
                    currentAnimator?.runtimeAnimatorController != locomotionController)
                {
                    // Receiver restores walking when replacing the active VRM.
                    // Its old Animator cannot remain the clock for the new body.
                    BindWalkingClock(currentAnimator);
                    Vector3 remaining = targetPosition - transform.position;
                    remaining.y = 0f;
                    targetArrivalElapsed = ArrivalElapsedForDistance(remaining.magnitude, 0f);
                    UpdateWalkingStride(remaining.magnitude);
                }
            }
            bool hasWalkingClock = locomotionActive && walkingStepSeconds > 0f;
            bool finishStep = hasWalkingClock && settleAtTarget;
            bool hasWalkingPhase = false;
            float observedFootfallElapsed = 0f;
            if (hasWalkingClock && WorldLocomotionPresentation.TryGetWalkingPhase(locomotionAnimator, out float phase))
            {
                if (hasWalkingPhaseOrigin && phase + .0001f < lastWalkingPhase)
                {
                    // A new walk state can restart its clock during a quick
                    // reversal. Rebase only the footfall observation; never
                    // reset ground travel or pull the owner backward.
                    walkingPhaseBaseElapsed = locomotionElapsed;
                    hasWalkingPhaseOrigin = false;
                    Vector3 remaining = targetPosition - transform.position;
                    remaining.y = 0f;
                    targetArrivalElapsed = walkingPhaseBaseElapsed + ArrivalElapsedForDistance(remaining.magnitude, 0f);
                    UpdateWalkingStride(remaining.magnitude);
                }
                if (!hasWalkingPhaseOrigin)
                {
                    walkingPhaseOrigin = Mathf.Floor(phase * 2f) * .5f;
                    hasWalkingPhaseOrigin = true;
                }
                lastWalkingPhase = phase;
                observedFootfallElapsed = walkingPhaseBaseElapsed +
                    (phase - walkingPhaseOrigin) * 2f * walkingStepSeconds;
                hasWalkingPhase = true;
            }
            bool awaitingFootfall = finishStep && hasWalkingPhase &&
                observedFootfallElapsed + .00001f < targetArrivalElapsed &&
                locomotionElapsed < targetArrivalElapsed +
                    Mathf.Max(.25f, walkingStepSeconds * 1.5f);
            Vector3 remainingPlanar=targetPosition-transform.position;remainingPlanar.y=0;
            bool shouldMove = personalHomePresentation
                ? locomotionActive && remainingPlanar.sqrMagnitude>.000001f
                : !settleAtTarget && locomotionActive || (finishStep
                ? locomotionElapsed < targetArrivalElapsed || awaitingFootfall
                : WorldLocomotionPresentation.ShouldMove(transform.position, targetPosition, locomotionActive));
            SetLocomotion(shouldMove);
            if (!shouldMove)
            {
                transform.SetPositionAndRotation(
                    targetPosition,
                    WorldLocomotionPresentation.AdvanceRotation(
                        transform.rotation,
                        targetRotation,
                        delta));
                return;
            }

            Vector3 currentPosition = transform.position;
            float movementDelta = delta;
            float segmentDelta = movementDelta;
            bool reachedRoutePoint = !settleAtTarget &&
                Vector3.Distance(currentPosition, targetPosition) <= NavigationWalkingSpeed * movementDelta;
            if (reachedRoutePoint)
                segmentDelta = Vector3.Distance(currentPosition, targetPosition) / NavigationWalkingSpeed;
            // The Animator may sample at 30 Hz while the owner renders at
            // 60 Hz. Driving root travel from normalizedTime produced an
            // alternating 0 / double-step displacement on the device.
            // Advance distance continuously; the actual phase above only
            // guards the final footfall before returning to idle.
            Vector3 nextPosition = finishStep
                ? Vector3.Lerp(currentPosition, targetPosition,
                    Mathf.Clamp01(movementDelta / Mathf.Max(.000001f, targetArrivalElapsed - locomotionElapsed)))
                : Vector3.MoveTowards(currentPosition, targetPosition, NavigationWalkingSpeed * delta);
            targetRotation = WorldLocomotionPresentation.ResolveFacing(
                currentPosition,
                nextPosition,
                targetRotation);
            Quaternion nextRotation =
                WorldLocomotionPresentation.AdvanceRotation(
                    transform.rotation,
                    targetRotation,
                    segmentDelta);
            transform.SetPositionAndRotation(nextPosition, nextRotation);
            locomotionElapsed += segmentDelta;
            if(personalHomePresentation && settleAtTarget &&
                Vector3.Distance(nextPosition,targetPosition)<.00001f)SetLocomotion(false);
            if (finishStep && locomotionElapsed + .00001f >= targetArrivalElapsed &&
                !awaitingFootfall)
            {
                transform.position = targetPosition;
                SetLocomotion(false);
            }
            if (reachedRoutePoint && routeContinuation != null && routeContinuationDepth < 64)
            {
                var continuation = routeContinuation;
                var currentReceiver = receiver;
                Transform currentAvatar = AvatarRoot;
                Vector3 previousTarget = targetPosition;
                routeContinuationDepth++;
                try
                {
                    bool validRoute = continuation();
                    if (routeContinuation != continuation || !bound || receiver != currentReceiver || AvatarRoot != currentAvatar) return;
                    if (!validRoute)
                    {
                        routeContinuation = null;
                        if (currentAvatar != null && currentAvatar.IsChildOf(transform)) SetLocomotion(false);
                        return;
                    }
                    float remainingDelta = movementDelta - segmentDelta;
                    if (locomotionActive && worldVisible && !returningHome && remainingDelta > .000001f &&
                        (settleAtTarget || (targetPosition - previousTarget).sqrMagnitude > .000001f))
                        AdvanceLocomotion(remainingDelta);
                }
                finally { routeContinuationDepth--; }
            }
            else if (reachedRoutePoint) locomotionElapsed += movementDelta - segmentDelta;
        }

        private void UpdateReturnToHome()
        {
            if (homeAnchor == null || returnDuration <= 0f)
            {
                CompleteReturnToHome();
                return;
            }

            float progress = Mathf.Clamp01(
                (Time.realtimeSinceStartup - returnStartedAt) / returnDuration);
            float eased = Mathf.SmoothStep(0f, 1f, progress);
            transform.SetPositionAndRotation(
                Vector3.Lerp(returnStartPosition, homeAnchor.position, eased),
                Quaternion.Slerp(returnStartRotation, homeAnchor.rotation, eased));
            if (progress >= 1f)
            {
                CompleteReturnToHome();
            }
        }

        private void UpdateWalkingStride(float remainingDistance)
        {
            // Completing a footfall preserves continuity, but playing a full
            // stride over a 12 cm tap makes the feet slide. Scale the pose's
            // stride to the actual velocity of this planned segment. The blend
            // keeps the same cycle duration, so retargeting never resets gait.
            float seconds = targetArrivalElapsed - locomotionElapsed;
            float stride = !settleAtTarget ? 1f : seconds > .000001f
                ? remainingDistance / (seconds * NavigationWalkingSpeed) : 0f;
            WorldLocomotionPresentation.ApplyWalkingStride(locomotionAnimator, stride);
        }

        private float ArrivalElapsedForDistance(float distance, float elapsed)
        {
            if (!settleAtTarget) return elapsed + distance / NavigationWalkingSpeed;
            // Preserve the shared gait clock's distance units for navigation.
            return WorldLocomotionPresentation.ArrivalAtStepBoundary(
                distance * WorldLocomotionPresentation.WalkingSpeedMetersPerSecond / NavigationWalkingSpeed,
                elapsed, walkingStepSeconds);
        }

        private void EnsureCurrentAvatarGrounded()
        {
            Transform activeAvatar = AvatarRoot;
            if (activeAvatar == null || activeAvatar == groundedAvatar)
            {
                return;
            }
            if (WorldAvatarGrounding.TryGround(
                    activeAvatar,
                    PersistentWorldMapController.GroundY,
                    out _))
            {
                receiver?.RebaseActiveAvatarRootPose();
                groundedAvatar = activeAvatar;
            }
        }

        private void SetLocomotion(bool active)
        {
            if (locomotionActive == active)
            {
                return;
            }

            locomotionActive = active;
            receiver?.SetWorldLocomotion(active);
            if (active)
            {
                BindWalkingClock(AvatarRoot?.GetComponentInChildren<Animator>(true));
            }
            else
            {
                locomotionElapsed = 0f;
                walkingPhaseBaseElapsed = 0f;
                walkingStepSeconds = 0f;
                targetArrivalElapsed = 0f;
                hasWalkingPhaseOrigin = false;
                locomotionAnimator = null;
                locomotionController = null;
            }
        }

        private void BindWalkingClock(Animator currentAnimator)
        {
            WorldLocomotionPresentation.ApplyWalkingAnimationSpeed(currentAnimator, true, NavigationWalkingSpeed);
            locomotionElapsed = 0f;
            walkingPhaseBaseElapsed = 0f;
            hasWalkingPhaseOrigin = false;
            locomotionAnimator = currentAnimator;
            locomotionController = currentAnimator?.runtimeAnimatorController;
            // Personal-room navigation owns continuous travel. A short click
            // must not stretch its last segment to an authored half-cycle or
            // wait for a stale/paused Animator sample before blending to idle.
            walkingStepSeconds = personalHomePresentation ? 0f :
                WorldLocomotionPresentation.WalkingStepDurationSeconds(currentAnimator);
        }

        private void OnDestroy()
        {
            CompleteReturnToHome();
        }
    }
}
