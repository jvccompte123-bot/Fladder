import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';

/// Only used for the AVPlayer PiP handoff. MPV keeps its normal device profile.
/// HLS preserves the encoded aspect ratio; selected subtitles are burned in
/// because Flutter/libass overlays cannot be rendered by AVKit.
const iosPipProfile = DeviceProfile(
  name: 'Fladder iOS PiP',
  maxStreamingBitrate: 20000000,
  directPlayProfiles: [],
  transcodingProfiles: [
    TranscodingProfile(
      container: 'ts',
      type: DlnaProfileType.video,
      videoCodec: 'h264',
      audioCodec: 'aac',
      protocol: MediaStreamProtocol.hls,
      context: EncodingContext.streaming,
      maxAudioChannels: '2',
      minSegments: 2,
      breakOnNonKeyFrames: false,
    ),
  ],
  codecProfiles: [
    CodecProfile(type: CodecType.video, codec: 'h264', conditions: [
      ProfileCondition(
          condition: ProfileConditionType.lessthanequal,
          property: ProfileConditionValue.videobitdepth,
          $Value: '8',
          isRequired: true),
      ProfileCondition(
          condition: ProfileConditionType.lessthanequal,
          property: ProfileConditionValue.videolevel,
          $Value: '52',
          isRequired: false),
      ProfileCondition(
          condition: ProfileConditionType.equalsany,
          property: ProfileConditionValue.videorangetype,
          $Value: 'SDR',
          isRequired: false),
      ProfileCondition(
          condition: ProfileConditionType.notequals,
          property: ProfileConditionValue.isinterlaced,
          $Value: 'true',
          isRequired: false),
    ]),
  ],
  subtitleProfiles: [
    SubtitleProfile(format: 'srt', method: SubtitleDeliveryMethod.encode),
    SubtitleProfile(format: 'subrip', method: SubtitleDeliveryMethod.encode),
    SubtitleProfile(format: 'vtt', method: SubtitleDeliveryMethod.encode),
    SubtitleProfile(format: 'ass', method: SubtitleDeliveryMethod.encode),
    SubtitleProfile(format: 'ssa', method: SubtitleDeliveryMethod.encode),
    SubtitleProfile(format: 'pgssub', method: SubtitleDeliveryMethod.encode),
    SubtitleProfile(format: 'dvdsub', method: SubtitleDeliveryMethod.encode),
  ],
);

PlaybackInfoDto iosPipPlaybackRequest({
  required String userId,
  String? mediaSourceId,
  String? liveStreamId,
  int? audioStreamIndex,
  int? subtitleStreamIndex,
  int? maxStreamingBitrate,
}) =>
    PlaybackInfoDto(
      userId: userId,
      deviceProfile: iosPipProfile,
      mediaSourceId: mediaSourceId,
      liveStreamId: liveStreamId,
      audioStreamIndex: audioStreamIndex,
      subtitleStreamIndex: subtitleStreamIndex,
      enableDirectPlay: false,
      enableDirectStream: false,
      enableTranscoding: true,
      allowVideoStreamCopy: true,
      allowAudioStreamCopy: true,
      autoOpenLiveStream: true,
      alwaysBurnInSubtitleWhenTranscoding: true,
      maxStreamingBitrate: (maxStreamingBitrate ?? 20000000).clamp(1, 20000000),
      // Jellyfin's VOD HLS playlist has the full movie timeline. Seek in AVPlayer,
      // not by shifting the server's timeline (and then seeking a second time).
      startTimeTicks: 0,
    );
