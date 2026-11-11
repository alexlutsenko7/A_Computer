// AAudioLinkFix: including this header makes Arduino link with
// -Wl,--wrap=bta_av_co_audio_set_codec (see library.properties).
// The sketch defines __wrap_bta_av_co_audio_set_codec.
#pragma once
