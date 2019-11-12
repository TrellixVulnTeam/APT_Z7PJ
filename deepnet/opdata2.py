import sys
import os
import numpy as np
import tensorflow as tf
import logging
import cv2

import matplotlib.pyplot as plt
from itertools import islice
import time

import PoseTools
import heatmap

ISPY3 = sys.version_info >= (3, 0)

def distsquaredpts2limb(zz, startxy, sehat):
    '''
    compute squared distance from pt to line

    :param zz: (2,n) array of coords (float type)
    :param startxy: (2,) array of starting pt in limb
    :param sehat: (2) unit vec pointing from limb0 to limb1

    :return: zzdist1 (2,n) array of squared distance from zz to line thru limb
    '''
    zzrel = zz - startxy[:, np.newaxis]
    zzrelmag2 = zzrel[0, :] ** 2 + zzrel[1, :] ** 2
    # zzrel dot startendhat
    zzrelmag2along = np.square(zzrel[0, :]*sehat[0] + zzrel[1, :]*sehat[1])
    zzdist2 = zzrelmag2 - zzrelmag2along
    return zzdist2


def distsquaredpts2limb2(zz, xs, ys, xe, ye, dse2):
    '''
    Prob better (numerically) version of distsquaredpts2limb
    xs, ys, xe, ye: x/ystart, x/yend
    dse2: (xe-xs)**2 + (ye-ys)**2
    '''

    assert zz.shape[0] == 2

    num = (ye - ys)*zz[0, :] - (xe - xs)*zz[1, :] + xe*ys - ye*xs
    zzdist2 = np.square(num) / dse2
    return zzdist2


def create_affinity_labels(locs, imsz, graph,
                           tubewidth=1.0,
                           tubeblur=False,
                           tubeblursig=None,
                           tubeblurclip=0.05):
    """
    Create/return part affinity fields

    locs: (nbatch x npts x 2) (x,y) locs, 0-based. (0,0) is the center of the
        upper-left pixel.
    imsz: [2] (nr, nc) size of affinity maps to create/return

    graph: (nlimb) array of 2-element tuples; connectivity/skeleton
    tubewidth: width of "limb". 
               - if tubeBlurred=False, the tube has "hard" edges with width==tubewidth.
                 *Warning* maybe don't choose tubewidth exactly equal to 1.0 in this case.
               - if tubeBlurred=True, then the tube has a clipped gaussian perpendicular
                 xsection. The stddev of this gaussian is tubeblursig. The tails of the
                 gaussian are clipped at tubeblurclip. 
                 
    In all cases the paf amplitude is in [0,1] ie the tube maximum is at y=1.

    returns (nbatch x imsz[0] x imsz[1] x nlimb*2) paf hmaps.
        4th dim ordering: limb1x, limb1y, limb2x, limb2y, ...
    """

    if tubeblur:
        # tubewidth ignored, tubeblursig must be set
        assert tubeblursig is not None, "tubeblursig must be set"
        # tube radius (squared) corresponding to clip limit tubeblurblip
        tuberadsq = -2.0 * tubeblursig**2 * np.log(tubeblurclip)
        tuberad = np.sqrt(tuberadsq)
        tubewidth = 2.0 * tuberad
        # only pixels within tuberad of the limb segment will fall inside clipping range
    else:
        if tubeblursig is not None:
            pass
            #logging.warning('Tubeblur is False; ignoring tubeblursig value')
        tuberad = tubewidth / 2.0

    nlimb = len(graph)
    nbatch = locs.shape[0]
    out = np.zeros([nbatch, imsz[0], imsz[1], nlimb * 2])
    n_steps = 2 * max(imsz)

    for cur in range(nbatch):
        for ndx, e in enumerate(graph):
            startxy = locs[cur, e[0], :]
            start_x, start_y = locs[cur, e[0], :]
            end_x, end_y = locs[cur, e[1], :]
            assert not (np.isnan(start_x) or np.isnan(start_y) or np.isnan(end_x) or np.isnan(end_y))
            assert not (np.isinf(start_x) or np.isinf(start_y) or np.isinf(end_x) or np.isinf(end_y))

            ll2 = (start_x - end_x) ** 2 + (start_y - end_y) ** 2
            ll = np.sqrt(ll2)

            if ll == 0:
                # Can occur if start/end labels identical
                # Don't update out/PAF
                continue

            costh = (end_x - start_x) / ll
            sinth = (end_y - start_y) / ll
            zz = None
            TUBESTEP = 0.25 # seems like overkill (smaller than nec)
            ntubestep = int(np.ceil(tubewidth / TUBESTEP + 1))
            for delta in np.linspace(-tuberad, tuberad, ntubestep):
                # delta indicates perpendicular displacement from line/limb segment (in px)

                xx = np.round(np.linspace(start_x + delta * sinth, end_x + delta * sinth, n_steps))
                yy = np.round(np.linspace(start_y - delta * costh, end_y - delta * costh, n_steps))
                if zz is None:
                    zz = np.stack([xx, yy])
                else:
                    zz = np.concatenate([zz, np.stack([xx, yy])], axis=1)
            # zz now has all the pixels that are along the line.
            # or "tube" of width tubewidth around limb
            zz = np.unique(zz, axis=1)
            # zz now has all the unique pixels that are along the line with thickness==tubewidth.
            # zz shape is (2, n)
            # zz is rounded, representing px centers; startxy is not rounded
            if tubeblur:
                # since zz is rounded, some points in zz may violate tubeblurclip.
                zzdist2 = distsquaredpts2limb2(zz, start_x, start_y, end_x, end_y, ll2)
                w = np.exp(-zzdist2/2.0/tubeblursig**2)
                # tfwsmall = w < tubeblurclip
                # if np.any(tfwsmall):
                #     print "Small w vals: {}/{}".format(np.count_nonzero(tfwsmall), tfwsmall.size)
                #     print w[tfwsmall]
                assert zz.shape[1] == w.size

                for i in range(w.size):
                    x, y = zz[:, i]
                    xint = int(round(x))  # should already be rounded
                    yint = int(round(y))  # etc
                    if xint < 0 or xint >= out.shape[2] or yint < 0 or yint >= out.shape[1]:
                        continue
                    out[cur, yint, xint, ndx * 2] = w[i] * costh
                    out[cur, yint, xint, ndx * 2 + 1] = w[i] * sinth

            else:
                for x, y in zz.T:
                    xint = int(round(x)) # already rounded?
                    yint = int(round(y)) # etc
                    if xint < 0 or xint >= out.shape[2] or yint < 0 or yint >= out.shape[1]:
                        continue
                    out[cur, yint, xint, ndx * 2] = costh
                    out[cur, yint, xint, ndx * 2 + 1] = sinth

    return out

def rescale_points(locs_hires, scale):
    '''
    Rescale (x/y) points to a lower res

    :param locs_hires: (nbatch x npts x 2) (x,y) locs, 0-based. (0,0) is the center of the upper-left pixel.
    :param scale: downsample factor. eg if 2, the image size is cut in half
    :return: (nbatch x npts x 2) (x,y) locs, 0-based, rescaled (lo-res)

    Should work fine with scale<1
    '''

    bsize, npts, d = locs_hires.shape
    assert d == 2
    assert issubclass(locs_hires.dtype.type, np.floating)
    locs_lores = (locs_hires - float(scale - 1) / 2) / scale
    return locs_lores

def unscale_points(locs_lores, scale):
    '''
    Undo rescale_points

    :param locs_lores:
    :param scale:
    :return:
    '''

    bsize, npts, d = locs_lores.shape
    assert d == 2
    assert issubclass(locs_lores.dtype.type, np.floating)
    locs_hires = float(scale) * (locs_lores + 0.5) - 0.5
    return locs_hires

def parse_record(record, npts):
    example = tf.train.Example()
    example.ParseFromString(record)
    height = int(example.features.feature['height'].int64_list.value[0])
    width = int(example.features.feature['width'].int64_list.value[0])
    depth = int(example.features.feature['depth'].int64_list.value[0])
    expid = int(example.features.feature['expndx'].float_list.value[0])
    t = int(example.features.feature['ts'].float_list.value[0])
    img_string = example.features.feature['image_raw'].bytes_list.value[0]
    img_1d = np.fromstring(img_string, dtype=np.uint8)
    reconstructed_img = img_1d.reshape((height, width, depth))
    locs = np.array(example.features.feature['locs'].float_list.value)
    locs = locs.reshape([npts, 2])
    if 'trx_ndx' in example.features.feature.keys():
        trx_ndx = int(example.features.feature['trx_ndx'].int64_list.value[0])
    else:
        trx_ndx = 0
    info = np.array([expid, t, trx_ndx])

    return reconstructed_img, locs, info

def pad_ims_blur(ims, locs, pady, padx):
    # Similar to PoseTools.pad_ims

    pady_b = pady//2 # before
    padx_b = padx//2
    pady_a = pady-pady_b # after
    padx_a = padx-padx_b
    zz = np.pad(ims, [[0, 0], [pady_b, pady_a], [padx_b, padx_a], [0, 0]], mode='edge')
    wt_im = np.ones(ims[0, :, :, 0].shape)
    wt_im = np.pad(wt_im, [[pady_b, pady_a], [padx_b, padx_a]], mode='linear_ramp')
    out_ims = zz.copy()
    for ex in range(ims.shape[0]):
        for c in range(ims.shape[3]):
            aa = cv2.GaussianBlur(zz[ex, :, :, c], (15, 15), 5)
            aa = aa * (1 - wt_im) + zz[ex, :, :, c] * wt_im
            out_ims[ex, :, :, c] = aa

    out_locs = locs.copy()
    out_locs[..., 0] += padx_b
    out_locs[..., 1] += pady_b
    return out_ims, out_locs

def pad_ims_edge(ims, locs, pady, padx):
    # Similar to PoseTools.pad_ims

    pady_b = pady//2 # before
    padx_b = padx//2
    pady_a = pady-pady_b # after
    padx_a = padx-padx_b
    out_ims = np.pad(ims, [[0, 0], [pady_b, pady_a], [padx_b, padx_a], [0, 0]], mode='edge')
    out_locs = locs.copy()
    out_locs[..., 0] += padx_b
    out_locs[..., 1] += pady_b
    return out_ims, out_locs

def pad_ims_black(ims, locs, pady, padx):
    # Similar to PoseTools.pad_ims

    pady_b = pady//2 # before
    padx_b = padx//2
    pady_a = pady-pady_b # after
    padx_a = padx-padx_b
    out_ims = np.pad(ims, [[0, 0], [pady_b, pady_a], [padx_b, padx_a], [0, 0]], mode='constant')
    out_locs = locs.copy()
    out_locs[..., 0] += padx_b
    out_locs[..., 1] += pady_b
    return out_ims, out_locs

def ims_locs_preprocess_openpose(ims, locs, conf, distort):
    '''
    Openpose; Preprocess ims/locs; generate targets
    :param ims:
    :param locs:
    :param conf:
    :param distort:
    :return:
    '''

    assert conf.op_rescale == 1, \
        "Need further mods/corrections below for op_rescale~=1"
    assert conf.op_label_scale == 8, \
        "Expected openpose scale of 8"  # Any value should be ok tho

    ims, locs = PoseTools.preprocess_ims(ims, locs, conf,
                                         distort, conf.op_rescale)
    # locs has been rescaled per op_rescale (but not op_label_scale)

    imszuse = conf.imszuse
    (imnr_use, imnc_use) = imszuse
    ims = ims[:, 0:imnr_use, 0:imnc_use, :]

    assert conf.img_dim == ims.shape[-1]
    if conf.img_dim == 1:
        ims = np.tile(ims, 3)

    # locs -> PAFs, MAP
    # Generates hires maps here but only used below if conf.op_hires
    dc_scale = conf.op_hires_ndeconv ** 2
    locs_lores = rescale_points(locs, conf.op_label_scale)
    locs_hires = rescale_points(locs, conf.op_label_scale // dc_scale)
    imsz_lores = [int(x / conf.op_label_scale / conf.op_rescale) for x in imszuse]
    imsz_hires = [int(x / conf.op_label_scale * dc_scale / conf.op_rescale) for x in imszuse]
    label_map_lores = heatmap.create_label_hmap(locs_lores, imsz_lores, conf.op_map_lores_blur_rad)
    label_map_hires = heatmap.create_label_hmap(locs_hires, imsz_hires, conf.op_map_hires_blur_rad)

    label_paf_lores = create_affinity_labels(locs_lores,
                                             imsz_lores,
                                             conf.op_affinity_graph,
                                             tubewidth=conf.op_paf_lores_tubewidth,
                                             tubeblur=conf.op_paf_lores_tubeblur,
                                             tubeblursig=conf.op_paf_lores_tubeblursig,
                                             tubeblurclip=conf.op_paf_lores_tubeblurclip)

    npafstg = conf.op_paf_nstage
    nmapstg = conf.op_map_nstage
    targets = [label_paf_lores, ] * npafstg + [label_map_lores, ] * nmapstg
    if conf.op_hires:
        targets.append(label_map_hires)

    return ims, locs, targets

__ims_locs_preprocess_sb_has_run__ = False

def ims_locs_preprocess_sb(imsraw, locsraw, conf, distort):
    '''
    Openpose; Preprocess ims/locs; generate targets
    :param ims:
    :param locs:
    :param conf:
    :param distort:
    :return:
    '''

    global __ims_locs_preprocess_sb_has_run__

    assert conf.sb_rescale == 1

    imspp, locspp = PoseTools.preprocess_ims(imsraw, locsraw, conf, distort, conf.sb_rescale)
    # locs has been rescaled per sb_rescale

    ims, locs = pad_ims_black(imspp, locspp, conf.sb_im_pady, conf.sb_im_padx)
    imszuse = conf.imszuse # post-pad dimensions (input to network)
    (imnr_use, imnc_use) = imszuse
    assert ims.shape[1] == imnr_use
    assert ims.shape[2] == imnc_use
    assert ims.shape[3] == conf.img_dim
    if conf.img_dim == 1:
        ims = np.tile(ims, 3)

    locs_outres = rescale_points(locs, conf.sb_output_scale)
    imsz_out = [int(x / conf.sb_output_scale) for x in imszuse]
    label_map_outres = heatmap.create_label_hmap(locs_outres,
                                                 imsz_out,
                                                 conf.sb_blur_rad_output_res)
    targets = [label_map_outres,]

    if not __ims_locs_preprocess_sb_has_run__:
        logging.info('sb preprocess. sb_out_scale={}, imszuse={}, imszout={}, blurradout={}'.format(conf.sb_output_scale, imszuse, imsz_out, conf.sb_blur_rad_output_res))
        __ims_locs_preprocess_sb_has_run__ = True

    return ims, locs, targets

def imgaug_augment(augmenter, images, keypoints):
    '''
    Apply an imgaug augmenter. C+P dpk/TrainingGenerator/augment; in Py3 can prob just call meth directly
    :param augmenter:
    :param images: NHWC
    :param keypoints: B x npts x 2
    :return:
    '''

    assert images.shape[0] == keypoints.shape[0] and keypoints.shape[2] == 2

    images_aug = []
    keypoints_aug = []
    for idx in range(images.shape[0]):
        images_idx = images[idx, None]
        keypoints_idx = keypoints[idx, None]
        augmented_idx = augmenter(images=images_idx, keypoints=keypoints_idx)
        images_aug_idx, keypoints_aug_idx = augmented_idx
        images_aug.append(images_aug_idx)
        keypoints_aug.append(keypoints_aug_idx)

    images_aug = np.concatenate(images_aug)
    keypoints_aug = np.concatenate(keypoints_aug)
    return images_aug, keypoints_aug


def ims_locs_preprocess_dpk(imsraw, locsraw, conf, distort):

    #assert conf.sb_rescale == 1 We do want something like this

    if distort:
        augmenter = conf.augmenter
        ims, locs = imgaug_augment(augmenter, imsraw, locsraw)
        #imspp, locspp = PoseTools.preprocess_ims(imsraw, locsraw, conf, distort, conf.sb_rescale)
        # locs has been rescaled per sb_rescale
    else:
        ims = imsraw
        locs = locsraw

    imszuse = conf.imszuse # post-pad dimensions (input to network)
    (imnr_use, imnc_use) = imszuse
    assert ims.shape[1] == imnr_use
    assert ims.shape[2] == imnc_use
    assert ims.shape[3] == conf.img_dim
    #if conf.img_dim == 1:
    #    ims = np.tile(ims, 3)

    #locs_outres = rescale_points(locs, conf.sb_output_scale)
    #imsz_out = [int(x / conf.sb_output_scale) for x in imszuse]
    #label_map_outres = heatmap.create_label_hmap(locs_outres,
    #                                             imsz_out,
    #                                             conf.sb_blur_rad_output_res)
    y = dpk.utils.keypoints.draw_confidence_maps(
        ims,
        locs,
        graph=conf.dpk_graph,
        output_shape=conf.dpk_output_shape,
        use_graph=conf.dpk_use_graph,
        sigma=conf.dpk_output_sigma
    )
    y *= 255
    if conf.dpk_use_graph:
        y[..., conf.n_classes:] *= conf.dpk_graph_scale  # scale grps, limbs, globals

    if conf.dpk_n_outputs > 1:
        y = [y for idx in range(conf.dpk_n_outputs)]

    targets = y
    #targets = [label_map_outres,]

    #if not __ims_locs_preprocess_sb_has_run__:
    #    logging.info('sb preprocess. sb_out_scale={}, imszuse={}, imszout={}, blurradout={}'.format(conf.sb_output_scale, imszuse, imsz_out, conf.sb_blur_rad_output_res))
    #    __ims_locs_preprocess_sb_has_run__ = True

    return ims, locs, targets



def data_generator(conf, db_type, distort, shuffle, ims_locs_proc_fn, debug=False):
    '''

    :param conf:
    :param db_type:
    :param distort:
    :param shuffle:
    :param ims_locs_proc_fn: fn(ims,locs,conf,distort) and returns ims,locs,targets
    :param debug:
    :return:
    '''
    if db_type == 'val':
        filename = os.path.join(conf.cachedir, conf.valfilename) + '.tfrecords'
    elif db_type == 'train':
        filename = os.path.join(conf.cachedir, conf.trainfilename) + '.tfrecords'
    else:
        raise IOError('Unspecified DB Type')  # KB 20190424 - py3

    isstr = isinstance(ims_locs_proc_fn, str) if ISPY3 else \
            isinstance(ims_locs_proc_fn, basestring)
    if isstr:
        ims_locs_proc_fn = globals()[ims_locs_proc_fn]

    batch_size = conf.batch_size
    N = PoseTools.count_records(filename)

    logging.info("opdata data gen. file={}, ppfun={}, N={}".format(
        filename, ims_locs_proc_fn.__name__, N))

    # Py 2.x workaround nested functions outer variable rebind
    # https://www.python.org/dev/peps/pep-3104/#new-syntax-in-the-binding-outer-scope
    class Namespace:
        pass

    ns = Namespace()
    ns.iterator = None

    def iterator_reset():
        if ns.iterator:
            ns.iterator.close()
        ns.iterator = tf.python_io.tf_record_iterator(filename)
        # print('========= Resetting ==========')

    def iterator_read_next():
        if not ns.iterator:
            ns.iterator = tf.python_io.tf_record_iterator(filename)
        try:
            if ISPY3:
                record = next(ns.iterator)
            else:
                record = ns.iterator.next()
        except StopIteration:
            iterator_reset()
            if ISPY3:
                record = next(ns.iterator)
            else:
                record = ns.iterator.next()
        return record

    while True:
        all_ims = []
        all_locs = []
        all_info = []
        for b_ndx in range(batch_size):
            # TODO: strange shuffle
            n_skip = np.random.randint(30) if shuffle else 0
            for _ in range(n_skip + 1):
                record = iterator_read_next()

            recon_img, locs, info = parse_record(record, conf.n_classes)
            all_ims.append(recon_img)
            all_locs.append(locs)
            all_info.append(info)

        imsraw = np.stack(all_ims)  # [bsize x height x width x depth]
        locsraw = np.stack(all_locs)  # [bsize x ncls x 2]
        info = np.stack(all_info)  # [bsize x 3]

        ims, locs, targets = ims_locs_proc_fn(imsraw, locsraw, conf, distort)
        # targets should be a list here

        if debug:
            yield [ims], targets, locs, info
        else:
            yield [ims], targets
            # (inputs, targets)

if __name__ == "__main__":

    # class Timer(object):
    #     def __init__(self, name=None):
    #         self.name = name
    #
    #     def __enter__(self):
    #         self.tstart = time.time()
    #
    #     def __exit__(self, type, value, traceback):
    #         if self.name:
    #             print('[%s]' % self.name,)
    #         print('Elapsed: %s' % (time.time() - self.tstart))
    #
    #
    # tf.enable_eager_execution()

    import nbHG
    print("OPD MAIN!")

    locs = np.array([[5., 10.], [15., 10.], [15., 20.], [10., 15.]], np.float32)
    locs = locs[np.newaxis, :, :]
    affg = np.array([[0, 1], [1, 2], [1, 3]])
    imsz = (25, 25,)
    paf0 = create_affinity_labels(locs, imsz, affg, tubewidth=0.95)
    paf1 = create_affinity_labels(locs, imsz, affg, tubeblur=True, tubeblursig=0.95)

    conf = nbHG.createconf(nbHG.lblbub, nbHG.cdir, 'cvi_outer3_easy__split0', 'bub', 'openpose', 0)
    #conf.op_affinity_graph = conf.op_affinity_graph[::2]
    conf.imszuse = (192, 192)
    conf.sb_im_padx = 192-181
    conf.sb_im_pady = 192 - 181
    conf.sb_output_scale = 2
    conf.sb_blur_rad_output_res = 1.5
    # dst, dstmd, dsv, dsvmd = create_tf_datasets(conf)
    ditrn = data_generator(conf, 'train', True, True, ims_locs_preprocess_sb, debug=True)
    dival = data_generator(conf, 'val', False, False, ims_locs_preprocess_sb, debug=True)

    xtrn = [x for x in islice(ditrn,5)]
    xval = [x for x in islice(dival,5)]

    #imstrn, pafsmapstrn, locstrn, mdtrn = zip(*xtrn)
    #mdlintrn = zip(imstrn, pafsmapstrn)

    #imsval, pafsmapsval, locsval, mdval = zip(*xval)
    #mdlinval = zip(imsval, pafsmapsval)

    #ds1, ds2, ds3 = create_tf_datasets(conf)
    #
    #
    # if True:
    #     x1 = [x for x in ds1.take(10)]
    #     x2 = [x for x in ds2.take(10)]
    #     x3 = [x for x in ds3.take(10)]
    #     #locs10 = [x for x in dslocsinfo.take(10)]
    # else:
    #     dst10 = [x for x in dst.take(1)]
    #     dst10md = [x for x in dstmd.take(1)]
    #     dsv10 = [x for x in dsv.take(1)]
    #     dsv10md = [x for x in dsvmd.take(1)]

    # N = 100
    # with Timer('tf.data'):
    #     xds = [x for x in dst.take(N)]
    # with Timer('it'):
    #     xit = []
    #     for i in range(N):
    #         xit.append(ditrn.next())



    # ds2,ds3,ds4 = test_dataset_with_rand()




# locs = np.array([[0,0],[0,1.5],[0,4],[0,6.9],[0,7.],[0,7.49],[0,7.51],[1,2],[10,12],[16,16]])
# locs = locs[np.newaxis,:,:]
# imsz = (48, 40)
# locsrs = rescale_points(locs, 8)
# imszrs = (6, 5)
#
# import matplotlib.pyplot as plt
# hm1 = create_label_images_with_rescale(locs,imsz,8,3)
# hm2 = heatmap.create_label_hmap(locsrs, imszrs, 3)
