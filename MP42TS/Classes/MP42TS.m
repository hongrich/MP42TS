#import "MP42TS.h"

#define GPAC_CONFIG_DARWIN
#define GPAC_IPHONE
#define GPAC_AMR_IN_STANDALONE
#define GPAC_DISABLE_3D
#define GPAC_MODULE_CUSTOM_LOAD
#define GPAC_DISABLE_ISOM_WRITE

#include <gpac/media_tools.h>
#include <gpac/constants.h>
#include <gpac/mpegts.h>

#ifdef GPAC_DISABLE_MPEG2TS_MUX
#error "Cannot compile MP42TS if GPAC is not built with MPEG2-TS Muxing support"
#endif

#ifdef GPAC_DISABLE_ISOM
#error "Cannot compile MP42TS if GPAC is not built with ISO File Format support"
#endif

#define PCR_MS 100
#define PSI_REFRESH_RATE GF_M2TS_PSI_DEFAULT_REFRESH_RATE
#define PROG_PCR_OFFSET 0
#define STARTING_PID 100

#pragma mark - M2TSSource

typedef struct {
    GF_ISOFile *mp4;
    u32 nb_streams, pcr_idx;
    GF_ESInterface streams[10];
} M2TSSource;

typedef struct {
    GF_ISOFile *mp4;
    u32 track, sample_number, sample_count;
    GF_ISOSample *sample;

    s64 ts_offset, cts_dts_shift;
    M2TSSource *source;
} GF_ESIMP4;

static GF_Err mp4_input_ctrl(GF_ESInterface *ifce, u32 act_type, void *param)
{
    GF_ESIMP4 *priv = (GF_ESIMP4 *)ifce->input_udta;
    if (!priv) {
        return GF_BAD_PARAM;
    }

    switch (act_type) {
        case GF_ESI_INPUT_DATA_FLUSH:
        {
            GF_ESIPacket pck;
            if (!priv->sample) {
                priv->sample = gf_isom_get_sample(priv->mp4, priv->track, priv->sample_number+1, NULL);
            }

            if (!priv->sample) {
                return GF_IO_ERR;
            }

            memset(&pck, 0, sizeof(GF_ESIPacket));

            pck.flags = GF_ESI_DATA_AU_START | GF_ESI_DATA_HAS_CTS;
            if (priv->sample->IsRAP) {
                pck.flags |= GF_ESI_DATA_AU_RAP;
            }
            pck.cts = priv->sample->DTS + priv->ts_offset;

            pck.dts = pck.cts;
            if (priv->cts_dts_shift) {
                pck.cts += + priv->cts_dts_shift;
                pck.flags |= GF_ESI_DATA_HAS_DTS;
            }

            if (priv->sample->CTS_Offset) {
                pck.cts += priv->sample->CTS_Offset;
                pck.flags |= GF_ESI_DATA_HAS_DTS;
            }

            pck.flags |= GF_ESI_DATA_AU_END;
            pck.data = priv->sample->data;
            pck.data_len = priv->sample->dataLength;
            pck.duration = gf_isom_get_sample_duration(priv->mp4, priv->track, priv->sample_number+1);
            ifce->output_ctrl(ifce, GF_ESI_OUTPUT_DATA_DISPATCH, &pck);

            gf_isom_sample_del(&priv->sample);
            priv->sample_number++;

            if (priv->sample_number==priv->sample_count) {
                if (!(ifce->caps & GF_ESI_STREAM_IS_OVER)) {
                    ifce->caps |= GF_ESI_STREAM_IS_OVER;
                }
            }
        }
            return GF_OK;

        case GF_ESI_INPUT_DESTROY:
            if (ifce->decoder_config) {
                gf_free(ifce->decoder_config);
                ifce->decoder_config = NULL;
            }
            gf_free(priv);
            ifce->input_udta = NULL;
            return GF_OK;
        default:
            return GF_BAD_PARAM;
    }
}

static GF_Err fill_isom_es_ifce(M2TSSource *source, GF_ESInterface *ifce, GF_ISOFile *mp4, u32 track_num)
{
    GF_ESIMP4 *priv;
    char *_lan;
    GF_ESD *esd;
    u64 avg_rate, duration;
    s32 ref_count;
    s64 mediaOffset;

    GF_SAFEALLOC(priv, GF_ESIMP4);
    if (!priv) {
        return GF_OUT_OF_MEM;
    }

    priv->mp4 = mp4;
    priv->track = track_num;
    priv->sample_count = gf_isom_get_sample_count(mp4, track_num);

    priv->source = source;
    memset(ifce, 0, sizeof(GF_ESInterface));
    ifce->stream_id = gf_isom_get_track_id(mp4, track_num);

    esd = gf_media_map_esd(mp4, track_num);

    if (esd) {
        ifce->stream_type = esd->decoderConfig->streamType;
        ifce->object_type_indication = esd->decoderConfig->objectTypeIndication;
        if (esd->decoderConfig->decoderSpecificInfo && esd->decoderConfig->decoderSpecificInfo->dataLength) {
            switch (esd->decoderConfig->objectTypeIndication) {
                case GPAC_OTI_AUDIO_AAC_MPEG4:
                case GPAC_OTI_AUDIO_AAC_MPEG2_MP:
                case GPAC_OTI_AUDIO_AAC_MPEG2_LCP:
                case GPAC_OTI_AUDIO_AAC_MPEG2_SSRP:
                case GPAC_OTI_VIDEO_MPEG4_PART2:
                    ifce->decoder_config = (char *)gf_malloc(sizeof(char)*esd->decoderConfig->decoderSpecificInfo->dataLength);
                    ifce->decoder_config_size = esd->decoderConfig->decoderSpecificInfo->dataLength;
                    memcpy(ifce->decoder_config, esd->decoderConfig->decoderSpecificInfo->data, esd->decoderConfig->decoderSpecificInfo->dataLength);
                    break;
                case GPAC_OTI_VIDEO_AVC:
                case GPAC_OTI_VIDEO_SVC:
                case GPAC_OTI_VIDEO_MVC:
                    gf_isom_set_nalu_extract_mode(mp4, track_num, GF_ISOM_NALU_EXTRACT_LAYER_ONLY | GF_ISOM_NALU_EXTRACT_INBAND_PS_FLAG | GF_ISOM_NALU_EXTRACT_ANNEXB_FLAG | GF_ISOM_NALU_EXTRACT_VDRD_FLAG);
                    break;
                case GPAC_OTI_SCENE_VTT_MP4:
                    ifce->decoder_config = (char *)gf_malloc(sizeof(char)*esd->decoderConfig->decoderSpecificInfo->dataLength);
                    ifce->decoder_config_size = esd->decoderConfig->decoderSpecificInfo->dataLength;
                    memcpy(ifce->decoder_config, esd->decoderConfig->decoderSpecificInfo->data, esd->decoderConfig->decoderSpecificInfo->dataLength);
                    break;
            }
        }
        gf_odf_desc_del((GF_Descriptor *)esd);
    }
    gf_isom_get_media_language(mp4, track_num, &_lan);
    if (!_lan || !strcmp(_lan, "und")) {
        ifce->lang = 0;
    } else {
        ifce->lang = GF_4CC(_lan[0],_lan[1],_lan[2],' ');
    }
    if (_lan) {
        gf_free(_lan);
    }

    ifce->timescale = gf_isom_get_media_timescale(mp4, track_num);
    ifce->duration = gf_isom_get_media_timescale(mp4, track_num);
    avg_rate = gf_isom_get_media_data_size(mp4, track_num);
    avg_rate *= ifce->timescale * 8;
    if (0!=(duration=gf_isom_get_media_duration(mp4, track_num))) {
        avg_rate /= duration;
    }

    if (gf_isom_has_time_offset(mp4, track_num)) {
        ifce->caps |= GF_ESI_SIGNAL_DTS;
    }

    ifce->bit_rate = (u32) avg_rate;
    ifce->duration = (Double) (s64) gf_isom_get_media_duration(mp4, track_num);
    ifce->duration /= ifce->timescale;

    ifce->input_ctrl = mp4_input_ctrl;
    if (priv != ifce->input_udta) {
        if (ifce->input_udta) {
            gf_free(ifce->input_udta);
        }
        ifce->input_udta = priv;
    }


    if (! gf_isom_get_edit_list_type(mp4, track_num, &mediaOffset)) {
        priv->ts_offset = mediaOffset;
    }

    if (gf_isom_has_time_offset(mp4, track_num)==2) {
        priv->cts_dts_shift = gf_isom_get_cts_to_dts_shift(mp4, track_num);
    }

    ifce->depends_on_stream = 0;
    ref_count = gf_isom_get_reference_count(mp4, track_num, GF_ISOM_REF_SCAL);
    if (ref_count > 0) {
        gf_isom_get_reference_ID(mp4, track_num, GF_ISOM_REF_SCAL, (u32) ref_count, &ifce->depends_on_stream);
    }

    return GF_OK;
}

static GF_Err openSource(M2TSSource *source, const char *src)
{
    memset(source, 0, sizeof(M2TSSource));

    GF_Err error;
    u32 i;
    u32 nb_tracks;
    u32 first_audio = 0;
    u32 first_other = 0;
    s64 min_offset = 0;
    u32 min_offset_timescale = 0;
    source->mp4 = gf_isom_open(src, GF_ISOM_OPEN_READ, 0);
    source->nb_streams = 0;
    /*on MPEG-2 TS, carry 3GPP timed text as MPEG-4 Part17*/
    gf_isom_text_set_streaming_mode(source->mp4, 1);
    nb_tracks = gf_isom_get_track_count(source->mp4);

    for (i=0; i<nb_tracks; i++) {
        Bool check_deps = 0;
        if (gf_isom_get_media_type(source->mp4, i+1) == GF_ISOM_MEDIA_HINT) {
            continue;
        }

        error = fill_isom_es_ifce(source, &source->streams[i], source->mp4, i+1);
        if (error != GF_OK) {
            return error;
        }
        if (min_offset > ((GF_ESIMP4 *)source->streams[i].input_udta)->ts_offset) {
            min_offset = ((GF_ESIMP4 *)source->streams[i].input_udta)->ts_offset;
            min_offset_timescale = source->streams[i].timescale;
        }

        switch(source->streams[i].stream_type) {
            case GF_STREAM_VISUAL:
                check_deps = 1;
                if (gf_isom_get_sample_count(source->mp4, i+1)>1) {
                    /*get first visual stream as PCR*/
                    if (!source->pcr_idx) {
                        source->pcr_idx = i+1;
                    }
                }
                break;
            case GF_STREAM_AUDIO:
                if (!first_audio) {
                    first_audio = i+1;
                }
                check_deps = 1;
                break;
            default:
                /*log not supported stream type: %s*/
                break;
        }
        source->nb_streams++;
        if (gf_isom_get_sample_count(source->mp4, i+1)>1) first_other = i+1;

        if (check_deps) {
            u32 k;
            Bool found_dep = 0;
            for (k=0; k<nb_tracks; k++) {
                if (gf_isom_get_media_type(source->mp4, k+1) != GF_ISOM_MEDIA_OD) {
                    continue;
                }

                /*this stream is not refered to by any OD, send as regular PES*/
                if (gf_isom_has_track_reference(source->mp4, k+1, GF_ISOM_REF_OD, gf_isom_get_track_id(source->mp4, i+1) )==1) {
                    found_dep = 1;
                    break;
                }
            }
            if (!found_dep) {
                source->streams[i].caps |= GF_ESI_STREAM_WITHOUT_MPEG4_SYSTEMS;
            }
        }
    }

    /*if no visual PCR found, use first audio*/
    if (!source->pcr_idx) {
        source->pcr_idx = first_audio;
    }
    if (!source->pcr_idx) {
        source->pcr_idx = first_other;
    }
    if (source->pcr_idx) {
        GF_ESIMP4 *priv;
        source->pcr_idx-=1;
        priv = source->streams[source->pcr_idx].input_udta;
        gf_isom_set_default_sync_track(source->mp4, priv->track);
    }

    if (min_offset < 0) {
        for (i=0; i<source->nb_streams; i++) {
            Double scale = source->streams[i].timescale;
            scale /= min_offset_timescale;
            ((GF_ESIMP4 *)source->streams[i].input_udta)->ts_offset += (s64) (-min_offset * scale);
        }
    }

    return GF_OK;
}

#pragma mark - MP42TS

@implementation MP42TS

+ (nullable NSData *)convertMP4ToTS:(nonnull NSData *)mp4Data error:(NSError * _Nullable *)error
{
    GF_Err err = GF_OK;
    NSData *output = nil;
    NSMutableData *outputData = [NSMutableData data];

    M2TSSource source;
    GF_M2TS_Mux *muxer = NULL;
    const char *ts_pck;
    u32 j;

    NSString *memPath = [NSString stringWithFormat:@"gmem://%@@%p", @(mp4Data.length), mp4Data.bytes];
    err = openSource(&source, memPath.UTF8String);
    if (err != GF_OK) {
        goto exit;
    }

    /***************************/
    /*   create mp42ts muxer   */
    /***************************/
    muxer = gf_m2ts_mux_new(0, PSI_REFRESH_RATE, 0);
    if (!muxer) {
        err = GF_OUT_OF_MEM;
        goto exit;
    }
    gf_m2ts_mux_use_single_au_pes_mode(muxer, GF_M2TS_PACK_AUDIO_ONLY);
    gf_m2ts_mux_set_pcr_max_interval(muxer, PCR_MS);

    /****************************************/
    /*   declare all streams to the muxer   */
    /****************************************/
    GF_M2TS_Mux_Program *program;
    u32 prog_pcr_offset = 0;
    program = gf_m2ts_mux_program_add(muxer, 1, STARTING_PID, PSI_REFRESH_RATE, prog_pcr_offset, GF_M2TS_MPEG4_SIGNALING_NONE);
    if (program) {
        for (j=0; j<source.nb_streams; j++) {
            /*likely an OD stream disabled*/
            if (!source.streams[j].stream_type) {
                continue;
            }

            Bool force_pes_mode = 0;
            gf_m2ts_program_stream_add(program, &source.streams[j], STARTING_PID+j+1, (source.pcr_idx==j) ? 1 : 0, force_pes_mode);
        }
    }

    muxer->flush_pes_at_rap = GF_FALSE;

    gf_m2ts_mux_update_config(muxer, 1);

    /*****************/
    /*   main loop   */
    /*****************/
    while (true) {
        u32 status;

        /*flush all packets*/
        while ((ts_pck = gf_m2ts_mux_process(muxer, &status, NULL)) != NULL) {
            [outputData appendBytes:ts_pck length:188];

            if (status>=GF_M2TS_STATE_PADDING) {
                break;
            }
        }

        if (status==GF_M2TS_STATE_EOS) {
            break;
        }
    }

    output = outputData;

exit:
    if (err != GF_OK && error != nil) {
        *error = [NSError errorWithDomain:@"MP42TSErrorDomain" code:err userInfo:nil];
    }

    if (muxer) {
        gf_m2ts_mux_del(muxer);
    }
    for (j=0; j<source.nb_streams; j++) {
        if (source.streams[j].input_ctrl) {
            source.streams[j].input_ctrl(&source.streams[j], GF_ESI_INPUT_DESTROY, NULL);
        }
        if (source.streams[j].input_udta) {
            gf_free(source.streams[j].input_udta);
        }
        if (source.streams[j].decoder_config) {
            gf_free(source.streams[j].decoder_config);
        }
    }
    if (source.mp4) {
        gf_isom_close(source.mp4);
    }
    return output;
}

@end
