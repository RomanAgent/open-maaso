using UnityEngine;

namespace Maaso.World
{
    [DisallowMultipleComponent]
    public sealed class WorldEnvironmentController : MonoBehaviour
    {
        [SerializeField] private WorldEnvironmentProfile profile;
        [SerializeField] private AudioSource ambientAudio;
        [SerializeField] private WindZone windZone;
        [SerializeField] private ParticleSystem[] particles = System.Array.Empty<ParticleSystem>();

        private bool speechActive;
        private float targetAmbientVolume = 1f;

        public bool IsWorldSessionActive { get; private set; }
        public bool IsApplicationPaused { get; private set; }

        private void Update()
        {
            AdvanceVolume(Time.unscaledDeltaTime);
        }

        private void OnApplicationPause(bool paused)
        {
            SetApplicationPaused(paused);
        }

        public void Configure(WorldEnvironmentProfile value)
        {
            profile = value;
            if (profile == null)
            {
                return;
            }

            targetAmbientVolume = speechActive
                ? profile.SpeechDuckedVolume
                : profile.AmbientVolume;
            if (ambientAudio != null)
            {
                if (profile.AmbientClip != null)
                {
                    ambientAudio.clip = profile.AmbientClip;
                }
                ambientAudio.loop = true;
                ambientAudio.playOnAwake = true;
                ambientAudio.volume = targetAmbientVolume;
                ambientAudio.mute = IsApplicationPaused;
                if (Application.isPlaying && ambientAudio.clip != null && !ambientAudio.isPlaying)
                {
                    ambientAudio.Play();
                }
            }
            ApplyWindState();
            ApplyParticleState();
        }

        public void SetWorldSessionActive(bool active)
        {
            IsWorldSessionActive = active;
            if (ambientAudio != null && !IsApplicationPaused)
            {
                ambientAudio.mute = false;
            }
        }

        public void SetSpeechActive(bool active)
        {
            speechActive = active;
            if (profile == null)
            {
                return;
            }
            targetAmbientVolume = active
                ? profile.SpeechDuckedVolume
                : profile.AmbientVolume;
            if (profile.SpeechDuckSeconds <= 0f && ambientAudio != null)
            {
                ambientAudio.volume = targetAmbientVolume;
            }
        }

        public void SetApplicationPaused(bool paused)
        {
            if (IsApplicationPaused == paused)
            {
                return;
            }
            IsApplicationPaused = paused;
            if (ambientAudio != null)
            {
                ambientAudio.mute = paused;
                if (Application.isPlaying)
                {
                    if (paused)
                    {
                        ambientAudio.Pause();
                    }
                    else if (ambientAudio.clip != null)
                    {
                        ambientAudio.UnPause();
                    }
                }
            }
            ApplyWindState();
            ApplyParticleState();
        }

        public void AdvanceForTests(float deltaSeconds)
        {
            AdvanceVolume(Mathf.Max(0f, deltaSeconds));
        }

        private void AdvanceVolume(float deltaSeconds)
        {
            if (ambientAudio == null || profile == null)
            {
                return;
            }
            float duration = Mathf.Max(0.0001f, profile.SpeechDuckSeconds);
            float fullRange = Mathf.Abs(profile.AmbientVolume - profile.SpeechDuckedVolume);
            float speed = fullRange / duration;
            ambientAudio.volume = Mathf.MoveTowards(
                ambientAudio.volume,
                targetAmbientVolume,
                speed * deltaSeconds);
        }

        private void ApplyWindState()
        {
            if (windZone == null || profile == null)
            {
                return;
            }
            windZone.windMain = IsApplicationPaused ? 0f : profile.WindMain;
            windZone.windTurbulence = IsApplicationPaused
                ? 0f
                : profile.WindTurbulence;
        }

        private void ApplyParticleState()
        {
            for (int index = 0; index < particles.Length; index++)
            {
                ParticleSystem system = particles[index];
                if (system == null)
                {
                    continue;
                }
                ParticleSystem.EmissionModule emission = system.emission;
                emission.enabled = !IsApplicationPaused;
                if (!Application.isPlaying)
                {
                    continue;
                }
                if (IsApplicationPaused)
                {
                    system.Pause(true);
                }
                else
                {
                    system.Play(true);
                }
            }
        }
    }
}
