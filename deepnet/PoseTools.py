from __future__ import division
from __future__ import print_function

# coding: utf-8

# In[ ]:

from past.builtins import cmp
from builtins import range
from past.utils import old_div
import numpy as np
import scipy, re
import math, h5py
# import caffe
from scipy import misc
from scipy import ndimage
import tensorflow as tf
import multiResData
import tempfile
#import cv2
#import PoseTrain
import myutils
import os
import stat
import cv2
from cvc import cvc
import math
import sys
import copy
from scipy import io
import json
from skimage import transform
import datetime
from scipy.ndimage.interpolation import zoom
from scipy import stats
import pickle
import yaml
import logging

# from matplotlib.backends.backend_agg import FigureCanvasAgg

ISPY3 = sys.version_info >= (3, 0)

# In[ ]:

# not used anymore
# def scalepatches(patch,scale,num,rescale,cropsz):
#     sz = patch.shape
#     assert sz[0]%( (scale**(num-1))*rescale) is 0,"patch size isn't divisible by scale"

def get_cmap(n_classes,map_name='jet'):
    import matplotlib.pyplot as plt
    from matplotlib import cm
    cmap = cm.get_cmap(map_name)
    return cmap(np.linspace(0, 1, n_classes))

def rescale_points(locs_hires, scalex, scaley):
    '''
    Rescale (x/y) points to a lower res. Returns a new array

    :param locs_hires: (nbatch x npts x 2) (x,y) locs, 0-based. (0,0) is the center of the upper-left pixel.
    :param scalex: float downsample factor. eg if 2, the image size is cut in half
    :return: (nbatch x npts x 2) (x,y) locs, 0-based, rescaled (lo-res)

    Should work fine with scale<1
    '''

    bsize, npts, d = locs_hires.shape
    assert d == 2
    assert issubclass(locs_hires.dtype.type, np.floating)
    locs_lores = locs_hires.copy()
    locs_lores[:, :, 0] = (locs_lores[:, :, 0] - float(scalex - 1) / 2) / scalex
    locs_lores[:, :, 1] = (locs_lores[:, :, 1] - float(scaley - 1) / 2) / scaley
    return locs_lores

def unscale_points(locs_lores, scalex, scaley):
    '''
    Undo rescale_points. Returns a new array

    :param locs_lores:
    :param scale:
    :return:
    '''

    bsize, npts, d = locs_lores.shape
    assert d == 2
    assert issubclass(locs_lores.dtype.type, np.floating)
    locs_hires = locs_lores.copy()
    locs_hires[:, :, 0] = float(scalex) * (locs_hires[:, :, 0] + 0.5) - 0.5
    locs_hires[:, :, 1] = float(scaley) * (locs_hires[:, :, 1] + 0.5) - 0.5
    return locs_hires

def scale_images(img, locs, scale, conf, **kwargs):
    sz = img.shape
    szy_ds = int(sz[1]//scale)
    szx_ds = int(sz[2]//scale)
    scaley_actual = sz[1]/szy_ds
    scalex_actual = sz[2]/szx_ds

    simg = np.zeros((sz[0], szy_ds, szx_ds, sz[3]))
    for ndx in range(sz[0]):
        # use anti_aliasing?
        if sz[3] == 1:
            simg[ndx, :, :, 0] = transform.resize(img[ndx, :, :, 0], simg.shape[1:3],
                                                  preserve_range=True, mode='edge', **kwargs)
        else:
            simg[ndx, :, :, :] = transform.resize(img[ndx, :, :, :], simg.shape[1:3],
                                                  preserve_range= True, mode='edge', **kwargs)

    # AL 20190909. see also create_label_images
    # new_locs = new_locs/scale
    new_locs = rescale_points(locs, scalex_actual, scaley_actual)

    return simg, new_locs


def normalize_mean(in_img, conf):
    zz = in_img.astype('float')
    if conf.normalize_img_mean:
        # subtract mean for each img.
        mm = zz.mean(axis=(1,2))
        xx = zz - mm[:, np.newaxis, np.newaxis,:]
        if conf.img_dim == 3:
            if conf.perturb_color:
                for dim in range(3):
                    to_add = old_div(((np.random.rand(conf.batch_size) - 0.5) * conf.imax), 8)
                    xx[:, :, :, dim] += to_add[:, np.newaxis, np.newaxis]
    # elif not hasattr(conf, 'normalize_batch_mean') or conf.normalize_batch_mean:
    elif conf.normalize_batch_mean:
        # subtract the batch mean if the variable is not defined.
        # don't know why I have it. :/
        xx = zz - zz.mean()
    else:
        xx = zz
#     xx = xx.astype('uint8')
    return xx

def adjust_contrast(in_img, conf):
    if conf.adjust_contrast:
        clahe = cv2.createCLAHE(
            clipLimit=2.0,
            tileGridSize=(conf.clahe_grid_size, conf.clahe_grid_size))
        simg = np.zeros(in_img.shape)
        if in_img.shape[3] == 1:
            for ndx in range(in_img.shape[0]):
                simg[ndx, :, :, 0] = clahe.apply(in_img[ndx,:,:,0 ].astype('uint8')).astype('float')
        else:
            for ndx in range(in_img.shape[0]):
                lab = cv2.cvtColor(in_img[ndx,...], cv2.COLOR_RGB2LAB)
                lab_planes = cv2.split(lab)
                lab_planes[0] = clahe.apply(lab_planes[0])
                lab = cv2.merge(lab_planes)
                rgb = cv2.cvtColor(lab, cv2.COLOR_LAB2RGB)
                simg[ndx,...] = rgb
        return simg
    else:
        return in_img


def process_image(frame_in, conf):
    #     cropx = (framein.shape[0] - conf.imsz[0])/2
    #     cropy = (framein.shape[1] - conf.imsz[1])/2
    #     if cropx > 0:
    #         framein = framein[cropx:-cropx,:,:]
    #     if cropy > 0:
    #         framein = framein[:,cropy:-cropy,:]
    frame_in = crop_images(frame_in, conf)
    frame_in = frame_in[np.newaxis, :, :, 0:1]
    x0, x1, x2 = multi_scale_images(frame_in, conf.rescale, conf.scale, conf.l1_cropsz)
    return x0, x1, x2


def crop_images(frame_in, conf):
    cshape = tuple(frame_in.shape[0:2])
    start = conf.cropLoc[cshape]  # cropLoc[0] should be for y.
    end = [conf.imsz[ndx] + start[ndx] for ndx in range(2)]
    return frame_in[start[0]:end[0], start[1]:end[1], :]


def randomly_flip_lr(img, in_locs, conf, group_sz = 1):
    locs = in_locs.copy()
    if locs.ndim == 3:
        reduce_dim = True
        locs = locs[:,np.newaxis,...]
    else:
        reduce_dim = False

    num = img.shape[0]
    n_groups = num//group_sz
    orig_locs = locs.copy()
    pairs = conf.flipLandmarkMatches
    wd = img.shape[2]
    for ndx in range(n_groups):
        st = ndx*group_sz
        en = (ndx+1)*group_sz
        jj = np.random.randint(2)
        if jj > 0.5:
            img[st:en, ...] = img[st:en, :, ::-1, :]
            for ll in range(locs.shape[2]):
                str_ll = '{}'.format(ll)
                if str_ll in pairs.keys():
                    match = pairs[str_ll]
                    locs[st:en, :, ll, 0] = wd - 1 - orig_locs[st:en, :, match, 0]
                    locs[st:en, :, ll, 1] = orig_locs[st:en, :, match, 1]
                else:
                    locs[st:en, :, ll, 0] = wd - 1 - orig_locs[st:en, :, ll, 0]

    locs = locs[:, 0, ...] if reduce_dim else locs
    return img, locs


def randomly_flip_ud(img, in_locs, conf, group_sz = 1):
    locs = in_locs.copy()
    if locs.ndim == 3:
        reduce_dim = True
        locs = locs[:,np.newaxis,...]
    else:
        reduce_dim = False

    num = img.shape[0]
    n_groups = num//group_sz
    orig_locs = locs.copy()
    pairs = conf.flipLandmarkMatches
    ht = img.shape[1]
    for ndx in range(n_groups):
        st = ndx*group_sz
        en = (ndx+1)*group_sz
        jj = np.random.randint(2)
        if jj > 0.5:
            img[st:en, ...] = img[st:en, ::-1, : ,: ]
            for ll in range(locs.shape[2]):
                str_ll = '{}'.format(ll)
                if str_ll in pairs.keys():
                    match = pairs[ll]
                    locs[st:en, :, ll, 1] = ht - 1 - orig_locs[st:en, :, match , 1]
                    locs[st:en, :, ll, 0] = orig_locs[st:en, :, match , 0]
                else:
                    locs[st:en, :, ll, 1] = ht - 1 - orig_locs[st:en, :, ll, 1]

    locs = locs[:, 0, ...] if reduce_dim else locs
    return img, locs


def randomly_translate(img, locs, conf, group_sz = 1):
    if conf.trange < 1:
        return img, locs

    if locs.ndim == 3: # hack for multi animal
        reduce_dim = True
        locs = locs[:,np.newaxis,...]
    else:
        reduce_dim = False

    num = img.shape[0]
    rows, cols = img.shape[1:3]
    n_groups = num//group_sz
    for ndx in range(n_groups):
        st = ndx*group_sz
        en = (ndx+1)*group_sz
        orig_locs = copy.deepcopy(locs[st:en, ...])
        orig_im = copy.deepcopy(img[st:en, ...])
        sane = False
        do_move = True

        count = 0
        ll = orig_locs.copy()
        out_ii = orig_im.copy()
        while not sane:
            valid = np.invert(np.isnan(orig_locs[:,:, :, 0]))
            dx = np.round(np.random.randint(-conf.trange, conf.trange))
            dy = np.round(np.random.randint(-conf.trange, conf.trange))
            # round the random jitter so that there is no image distortions.
            count += 1
            if count > 5:
                dx = 0
                dy = 0
                sane = True
                do_move = False
            ll = copy.deepcopy(orig_locs)
            ll[:,:, :, 0] += dx
            ll[:,:, :, 1] += dy
            if np.all(ll[valid,0] >= 0) and \
                    np.all(ll[valid, 1] >= 0) and \
                    np.all(ll[valid, 0] < cols) and \
                    np.all(ll[valid, 1] < rows):
                sane = True
            elif not conf.check_bounds_distort:
                sane = True
            elif do_move:
                continue

            # else:
            #                 print 'not sane {}'.format(count)
            mat = np.float32([[1, 0, dx], [0, 1, dy]])
            for g in range(group_sz):
                ii = copy.deepcopy(orig_im[g,...])
                ii = cv2.warpAffine(ii, mat, (cols, rows),flags=cv2.INTER_CUBIC)#,borderMode=cv2.BORDER_REPLICATE)
                if ii.ndim == 2:
                    ii = ii[..., np.newaxis]
                out_ii[g,...] = ii
        locs[st:en, ...] = ll
        img[st:en, ...] = out_ii

    locs = locs[:, 0, ...] if reduce_dim else locs
    return img, locs


def randomly_rotate(img, locs, conf, group_sz = 1):
    if conf.rrange < 1:
        return img, locs

    if locs.ndim == 3: # hack for multi animal
        reduce_dim = True
        locs = locs[:,np.newaxis,...]
    else:
        reduce_dim = False

    num = img.shape[0]
    rows, cols = img.shape[1:3]
    rows = float(rows)
    cols = float(cols)
    n_groups = num//group_sz
    for ndx in range(n_groups):
        st = ndx*group_sz
        en = (ndx+1)*group_sz
        orig_locs = copy.deepcopy(locs[st:en, ...])
        orig_im = copy.deepcopy(img[st:en, ...])
        sane = False
        do_rotate = True

        count = 0
        lr = orig_locs.copy()
        out_ii = orig_im.copy()
        while not sane:
            valid = np.invert(np.isnan(orig_locs[:, :, :, 0]))
            rangle = (np.random.rand() * 2 - 1) * conf.rrange
            count += 1
            if count > 5:
                rangle = 0
                sane = True
                do_rotate = False
            ll = copy.deepcopy(orig_locs)
            ll = ll - [cols/2 , rows/2]
            ang = np.deg2rad(rangle)
            rot = [[np.cos(ang), -np.sin(ang)], [np.sin(ang), np.cos(ang)]]
            lr = np.zeros(ll.shape)
            for e_ndx in range(ll.shape[0]):
                for i_ndx in range(ll.shape[1]):
                    lr[e_ndx, i_ndx,...] = np.dot(ll[e_ndx, i_ndx], rot) + [old_div(cols, 2), old_div(rows, 2)]
            if np.all(lr[valid, 0] > 0) \
                    and np.all(lr[valid, 1] >0) \
                    and np.all(lr[valid, 0] <= cols) \
                    and np.all(lr[valid, 1] <= rows):
                sane = True
            elif not conf.check_bounds_distort:
                sane = True
            elif do_rotate:
                continue

            # else:
            #                 print 'not sane {}'.format(count)
            mat = cv2.getRotationMatrix2D((cols/2, rows/2), rangle, 1)
            for g in range(group_sz):
                ii = copy.deepcopy(orig_im[g,...])
                ii = cv2.warpAffine(ii, mat, (int(cols), int(rows)),flags=cv2.INTER_CUBIC)#,borderMode=cv2.BORDER_REPLICATE)
                if ii.ndim == 2:
                    ii = ii[..., np.newaxis]
                out_ii[g,...] = ii

        locs[st:en, ...] = lr
        img[st:en, ...] = out_ii

    locs = locs[:, 0, ...] if reduce_dim else locs
    return img, locs


def randomly_adjust(img, conf, group_sz = 1):
    # For images between 0 to 255
    # and single channel
    num = img.shape[0]
    brange = conf.brange
    bdiff = brange[1] - brange[0]
    crange = conf.crange
    cdiff = crange[1] - crange[0]
    imax = conf.imax
    if (bdiff<0.01) and (cdiff<0.01):
        return img
    n_groups = num//group_sz
    for ndx in range(n_groups):
        st = ndx*group_sz
        en = (ndx+1)*group_sz
        bfactor = np.random.rand() * bdiff + brange[0]
        cfactor = np.random.rand() * cdiff + crange[0]
        mm = img[st:en, ...].mean()
        for g in range(group_sz):
            jj = img[st+g, ...] + bfactor * imax
            jj = np.minimum(imax, (jj - mm) * cfactor + mm)
            jj = jj.clip(0, imax)
            img[st+g, ...] = jj
    return img


def randomly_scale(img,locs,conf,group_sz=1):
    # For images between 0 to 255
    # and single channel
    im_sz = img.shape[1:]
    num = img.shape[0]
    if conf.use_scale_factor_range:
        srange = conf.scale_factor_range
    else:
        srange = conf.scale_range
    if (conf.use_scale_factor_range and (srange > 1.0/1.01) and (srange < 1.01)) or \
       ((not conf.use_scale_factor_range) and srange < .01):
        return img, locs
    n_groups = num//group_sz
    for ndx in range(n_groups):
        st = ndx*group_sz
        en = (ndx+1)*group_sz
        if conf.use_scale_factor_range:
            # KB 20191218: first choose the scale factor
            # then decide whether to make it smaller or larger
            sfactor = 1.+np.random.rand()*np.abs(srange-1.)
            if np.random.rand() < 0.5:
                sfactor = 1.0/sfactor
        else:
            sfactor = (np.random.rand()-0.5)*srange + 1
            
        for g in range(group_sz):
            jj = img[st+g, ...].copy()
            # cur_img = zoom(jj, sfactor) if srange != 0 else jj
            if srange !=0:
                cur_img = cv2.resize(jj, None, fx= sfactor,fy=sfactor,interpolation=cv2.INTER_CUBIC)
                if cur_img.ndim == 2:
                    cur_img = cur_img[...,np.newaxis]
            else:
                cur_img = jj
            # cur_img = zoom(jj, sfactor,mode='reflect') if srange != 0 else jj
            cur_img, dx, dy = crop_to_size(cur_img, im_sz)
            img[st+g, ...] =cur_img
            locs[st+g,...,0] = locs[st+g,...,0]*sfactor + int(dx/2)
            locs[st + g, ..., 1] = locs[st + g, ..., 1]*sfactor + int(dy / 2)
    return img, locs


def randomly_affine(img,locs, conf, group_sz=1):

    # KB 20191218 - replaced scale_range with scale_factor_range
    if conf.use_scale_factor_range:
        srange = conf.scale_factor_range
    else:
        srange = conf.scale_range
    no_rescale = (conf.use_scale_factor_range and \
                  (srange > 1.0/1.01) and (srange < 1.01)) or \
                  ((not conf.use_scale_factor_range) and srange < .01)
    
    if conf.rrange < 1 and conf.trange< 1 and no_rescale:
        return img, locs

    locs = locs.copy()
    img = img.copy()
    if locs.ndim == 3: # hack for multi animal
        reduce_dim = True
        locs = locs[:,np.newaxis,...]
    else:
        reduce_dim = False

    num = img.shape[0]
    rows, cols = img.shape[1:3]
    rows = float(rows)
    cols = float(cols)
    n_groups = num//group_sz
    assert(num%group_sz==0), 'Incorrect group size'

    for ndx in range(n_groups):
        st = ndx*group_sz
        en = (ndx+1)*group_sz
        orig_locs = locs[st:en, ...]
        orig_im = img[st:en, ...].copy()
        sane = False
        do_rotate = True

        count = 0
        lr = orig_locs.copy()
        out_ii = orig_im.copy()
        while not sane:
            valid = np.invert(np.isnan(orig_locs[:, :, :, 0]))
            rangle = (np.random.rand() * 2 - 1) * conf.rrange

            if conf.use_scale_factor_range:
                # KB 20191218: first choose the scale factor
                # then decide whether to make it smaller or larger
                sfactor = 1.+np.random.rand()*np.abs(srange-1.)
                if np.random.rand() < 0.5:
                    sfactor = 1.0/sfactor
            else:
                sfactor = (np.random.rand()-0.5)*srange + 1

            # sfactor = (np.random.rand() - 0.5) * conf.scale_range + 1
            # clip scaling to 0.05
            if sfactor < 0.05:
                sfactor = 0.05
            dx = (np.random.rand()*2 -1)*conf.trange
            dy = (np.random.rand()*2 -1)*conf.trange

            count += 1
            if count > 5:
                rangle = 0; dx = 0; dy=0; sfactor = 1
                sane = True
                do_rotate = False

            rot_mat = cv2.getRotationMatrix2D((float(conf.imsz[1])/2,float(conf.imsz[0])/2 ), rangle, sfactor)
            rot_mat[0,2] += dx
            rot_mat[1,2] += dy
            lr = np.matmul(orig_locs,rot_mat[:,:2].T)
            lr[...,0] += rot_mat[0,2]
            lr[...,1] += rot_mat[1,2]

            if np.all(lr[valid, 0] > 0) \
                    and np.all(lr[valid, 1] >0) \
                    and np.all(lr[valid, 0] <= cols) \
                    and np.all(lr[valid, 1] <= rows):
                sane = True
            elif not conf.check_bounds_distort:
                sane = True
            elif do_rotate:
                continue

            for g in range(group_sz):
                ii = copy.deepcopy(orig_im[g,...])
                ii = cv2.warpAffine(ii, rot_mat, (int(cols), int(rows)),flags=cv2.INTER_CUBIC)
                if ii.ndim == 2:
                    ii = ii[..., np.newaxis]
                out_ii[g,...] = ii

        locs[st:en, ...] = lr
        img[st:en, ...] = out_ii

    locs = locs[:, 0, ...] if reduce_dim else locs
    return img, locs


def blur_label(im_sz, loc, scale, blur_rad):
    sz0 = int(math.ceil(old_div(float(im_sz[0]), scale)))
    sz1 = int(math.ceil(old_div(float(im_sz[1]), scale)))

    label = np.zeros([sz0, sz1])
    if not np.isnan(loc[0]):
        label[int(old_div(loc[0], scale)), int(old_div(loc[1], scale))] = 1
        #         blurL = ndimage.gaussian_filter(label,blur_rad)
        ksize = 2 * 3 * blur_rad + 1
        b_label = cv2.GaussianBlur(label, (ksize, ksize), blur_rad)
        b_label = old_div(b_label, b_label.max())
    else:
        b_label = label
    return b_label


def create_label_images_slow(locs, im_sz, scale, blur_rad):
    n_out = locs.shape[1]
    n_ex = locs.shape[0]
    sz0 = int(float(im_sz[0])/ scale)
    sz1 = int(float(im_sz[1])/ scale)
    out = np.zeros([n_ex,sz0,sz1,n_out])
    a, b = np.meshgrid(range(sz1), range(sz0))
    for cur in range(n_ex):
        for ndx in range(n_out):
            x = a - locs[cur,ndx,0]
            y = b - locs[cur,ndx,1]
            dd = np.sqrt(x**2+y**2)/blur_rad
            out[cur,:,:,ndx] = stats.norm.pdf(dd)/stats.norm.pdf(0)
    out[out<0.05] = 0.
    out = 2*out-1
    return  out


def create_label_images(locs, im_sz, scale, blur_rad):
    '''

    :param locs: original, hi-res locs
    :param im_sz: original, hi-res imsz
    :param scale: downsample fac
    :param blur_rad: gaussian/blur radius in output coord sys
    :return: [bsize x sz0_ds x sz1_ds x npts]

    Note: this uses pixel-centered template in the output/downsampled coord sys
    so is not subpixel-accurate

    '''
    n_classes = len(locs[0])
    sz0 = int(im_sz[0] // scale)
    sz1 = int(im_sz[1] // scale)

    # These may differ slightly from scale if im_sz is not evenly divisible by
    # scale.
    scaley_actual = im_sz[0]/sz0
    scalex_actual = im_sz[1]/sz1

    label_ims = np.zeros((len(locs), sz0, sz1, n_classes))
    # labelims1 = np.zeros((len(locs),sz0,sz1,n_classes))
    k_size = max(int(round(3 * blur_rad)),1)
    blur_l = np.zeros([2 * k_size + 1, 2 * k_size + 1])
    blur_l[k_size, k_size] = 1
    blur_l = cv2.GaussianBlur(blur_l, (2 * k_size + 1, 2 * k_size + 1), blur_rad)
    blur_l = old_div(blur_l, blur_l.max())
    for cls in range(n_classes):
        for ndx in range(len(locs)):
            if np.isnan(locs[ndx][cls][0]) or np.isinf(locs[ndx][cls][0]):
                continue
            if np.isnan(locs[ndx][cls][1]) or np.isinf(locs[ndx][cls][1]):
                continue
                #             modlocs = [locs[ndx][cls][1],locs[ndx][cls][0]]
            #             labelims1[ndx,:,:,cls] = blurLabel(imsz,modlocs,scale,blur_rad)

            yy = float(locs[ndx][cls][1]-float(scaley_actual-1)/2)/scaley_actual
            xx = float(locs[ndx][cls][0]-float(scalex_actual-1)/2)/scalex_actual
            modlocs0 = int(np.round(yy))  # AL 20200113 not subpixel
            modlocs1 = int(np.round(xx))  # AL 20200113 not subpixel
            l0 = min(sz0, max(0, modlocs0 - k_size))
            r0 = max(0, min(sz0, modlocs0 + k_size + 1))
            l1 = min(sz1, max(0, modlocs1 - k_size))
            r1 = max(0, min(sz1, modlocs1 + k_size + 1))
            label_ims[ndx, l0:r0, l1:r1, cls] = blur_l[(l0 - modlocs0 + k_size):(r0 - modlocs0 + k_size),
                                                (l1 - modlocs1 + k_size):(r1 - modlocs1 + k_size)]

    # label_ims = 2.0 * (label_ims - 0.5)
    label_ims -= 0.5
    label_ims *= 2.0
    return label_ims


def create_affinity_labels(locs, im_sz, graph, scale, blur_rad):
    """
    Create/return part affinity fields
    locs: (nbatch x npts x 2)
    graph: is an array of 2-element tuple
    scale: How much the PAF should be downsampled as compared to input image.
    blur_rad is the thickness of the PAF.
    """

    n_out = len(graph)
    n_ex = locs.shape[0]

    sz0 = int(im_sz[0] // scale)
    sz1 = int(im_sz[1] // scale)

    out = np.zeros((len(locs), sz0, sz1, n_out*2))
    n_steps = min(sz0,sz1)*2
    for cur in range(n_ex):
        for ndx, e in enumerate(graph):
            start_x, start_y = locs[cur,e[0],:]
            end_x, end_y = locs[cur,e[1],:]
            ll = np.sqrt( (start_x-end_x)**2 + (start_y-end_y)**2)

            if ll==0:
                # Can occur if start/end labels identical
                # Don't update out/PAF
                continue

            dx = (end_x - start_x)/ll/2
            dy = (end_y - start_y)/ll/2
            zz = None
            # AL: worried this creates a "tube" of width blur_rad/2 instead of blur_rad because
            # dx and dy above already have a factor of 1/2. c.f. open_pose/create_affinity_labels
            for delta in np.arange(-blur_rad/2,blur_rad/2,0.25):
                xx = np.round(np.linspace(start_x+delta*dy,end_x+delta*dy,n_steps))
                yy = np.round(np.linspace(start_y-delta*dx,end_y-delta*dx,n_steps))
                if zz is None:
                    zz = np.stack([xx,yy])
                else:
                    zz = np.concatenate([zz,np.stack([xx,yy])],axis=1)
            # zz now has all the pixels that are along the line.
            zz = np.unique(zz,axis=1)
            # zz now has all the unique pixels that are along the line with thickness blur_rad.
            dx = (end_x - start_x) / ll
            dy = (end_y - start_y) / ll
            for x,y in zz.T:
                if x >= out.shape[2] or y >= out.shape[1]:
                    continue
                out[cur,int(y),int(x),ndx*2] = dx
                out[cur,int(y),int(x),ndx*2+1] = dy

    return out


def create_reg_label_images(locs, im_sz, scale, blur_rad):
    n_classes = len(locs[0])
    sz0 = int(math.ceil(old_div(float(im_sz[0]), scale)))
    sz1 = int(math.ceil(old_div(float(im_sz[1]), scale)))

    labelims = np.zeros((len(locs), sz0, sz1, n_classes))
    regimsx = np.zeros((len(locs), sz0, sz1, n_classes))
    regimsy = np.zeros((len(locs), sz0, sz1, n_classes))
    for cls in range(n_classes):
        for ndx in range(len(locs)):
            # x,y = np.meshgrid(np.arange(sz0),np.arange(sz1))
            modlocs = [locs[ndx][cls][1], locs[ndx][cls][0]]
            labelims[ndx, :, :, cls] = blur_label(im_sz, modlocs, scale, blur_rad)

            #             np.sqrt((x-(round(locs[ndx][cls][0]/scale)))**2 +
            #                                (y-(round(locs[ndx][cls][1]/scale)))**2) < (rad-1)
            #             xmin = int(max(round((locs[ndx][cls][0])/scale - rad),0))
            #             xmax = int(min(round((locs[ndx][cls][0])/scale + rad),sz0))
            #             ymin = int(max(round((locs[ndx][cls][1])/scale - rad),0))
            #             ymax = int(min(round((locs[ndx][cls][1])/scale + rad),sz0))
            #             labelims[ndx,ymin:ymax,xmin:xmax,cls] = 1.
            tx, ty = np.meshgrid(np.arange(sz0) * scale, np.arange(sz1) * scale)
            tregx = tx.astype('float64')
            tregy = ty.astype('float64')
            tregx = locs[ndx][cls][0] - 1 - tregx
            tregy = locs[ndx][cls][1] - 1 - tregy
            regimsx[ndx, :, :, cls] = tregx
            regimsy[ndx, :, :, cls] = tregy

    labelims = 2.0 * (labelims - 0.5)
    return labelims, regimsx, regimsy


def arg_max_2d(x_in):
    orig_shape = tf.shape(x_in)
    reshape_t = tf.concat([orig_shape[0:1], [-1], orig_shape[3:4]], 0)
    zz = tf.reshape(x_in, reshape_t)
    pp = tf.to_int32(tf.argmax(zz, 1))
    sz1 = tf.slice(orig_shape, [2], [1])
    cc1 = tf.div(pp, tf.to_int32(sz1))
    cc2 = tf.mod(pp, tf.to_int32(sz1))

    return tf.stack([cc1, cc2])


def get_base_pred_locs(pred, conf):
    pred_locs = np.zeros([pred.shape[0], conf.n_classes, 2])
    for ndx in range(pred.shape[0]):
        for cls in range(conf.n_classes):
            max_ndx = np.argmax(pred[ndx, :, :, cls])
            cur_loc = np.array(np.unravel_index(max_ndx, pred.shape[1:3]))
            cur_loc = cur_loc * conf.pool_scale * conf.rescale
            pred_locs[ndx, cls, 0] = cur_loc[1]
            pred_locs[ndx, cls, 1] = cur_loc[0]
    return pred_locs


def get_pred_locs(pred, edge_ignore=0):
    if edge_ignore < 1:
        edge_ignore = 0
    n_classes = pred.shape[3]
    pred_locs = np.zeros([pred.shape[0], n_classes, 2])
    for ndx in range(pred.shape[0]):
        for cls in range(n_classes):
            cur_pred = pred[ndx, :, :, cls].copy()
            if edge_ignore > 0:
                cur_pred[:edge_ignore,:] = cur_pred.min()
                cur_pred[:,:edge_ignore] = cur_pred.min()
                cur_pred[-edge_ignore:,:] = cur_pred.min()
                cur_pred[:,-edge_ignore:] = cur_pred.min()
            maxndx = np.argmax(cur_pred)
            curloc = np.array(np.unravel_index(maxndx, pred.shape[1:3]))
            pred_locs[ndx, cls, 0] = curloc[1]
            pred_locs[ndx, cls, 1] = curloc[0]
    return pred_locs


def get_pred_locs_multi(pred, n_max, sz):
    pred = pred.copy()
    n_classes = pred.shape[3]
    pred_locs = np.zeros([pred.shape[0], n_max, n_classes, 2])
    for ndx in range(pred.shape[0]):
        for cls in range(n_classes):
            for count in range(n_max):
                maxndx = np.argmax(pred[ndx, :, :, cls])
                curloc = np.array(np.unravel_index(maxndx, pred.shape[1:3]))
                pred_locs[ndx, count, cls, 0] = curloc[1]
                pred_locs[ndx, count, cls, 1] = curloc[0]
                miny = max(curloc[0]-sz,0)
                maxy = min(curloc[0]+sz,pred.shape[1])
                minx = max(curloc[1]-sz,0)
                maxx = min(curloc[1]+sz,pred.shape[2])
                pred[ndx, miny:maxy, minx:maxx, cls] = pred.min()
    return pred_locs


def get_vars(vstr):
    var_list = tf.global_variables()
    b_list = []
    for var in var_list:
        if re.match(vstr, var.name):
            b_list.append(var)
    return b_list


def compare_conf(curconf, oldconf):
    ff = list(set(dir(curconf))|set(dir(oldconf)))
    for f in ff:
        if f[0:2] == '__' or f[0:3] == 'get':
            continue
        if hasattr(curconf, f) and hasattr(oldconf, f):
            if type(getattr(curconf, f)) is np.ndarray:
                if not np.array_equal(getattr(curconf,f),getattr(oldconf,f)):
                    logging.warning('{} not equal'.format(f))
                    logging.warning('New:{}'.format(getattr(curconf, f)))
                    logging.warning('Old:{}'.format(getattr(oldconf, f)))

            elif type(getattr(curconf, f)) is list:
                if type(getattr(oldconf, f)) is list:
                    if cmp(getattr(curconf, f), getattr(oldconf, f)) !=0 :
                        logging.warning('{} doesnt match'.format(f))
                        logging.warning('New:{}'.format(getattr(curconf, f)))
                        logging.warning('Old:{}'.format(getattr(oldconf, f)))
                else:
                    logging.warning('%s doesnt match' % f)
                    logging.warning('New:{}'.format(getattr(curconf, f)))
                    logging.warning('Old:{}'.format(getattr(oldconf, f)))
            elif callable(getattr(curconf,f)):
                pass
            elif getattr(curconf, f) != getattr(oldconf, f):
                logging.warning('%s doesnt match' % f)
                logging.warning('New:{}'.format(getattr(curconf, f)))
                logging.warning('Old:{}'.format(getattr(oldconf, f)))

        else:
            logging.warning('%s doesnt match' % f)
            if not hasattr(curconf,f):
                logging.warning('New does not have {}'.format(f))
            else:
                logging.warning('Old does not have {}'.format(f))


def open_movie(movie_name):
    cap = cv2.VideoCapture(movie_name)
    nframes = int(cap.get(cvc.FRAME_COUNT))
    return cap, nframes


def create_pred_image(pred_scores, n_classes):
    im = np.zeros(pred_scores.shape[0:2] + (3,))
    im[:, :, 0] = np.argmax(pred_scores, 2).astype('float32') / n_classes * 180
    im[:, :, 1] = (np.max(pred_scores, 2) + 1) / 2 * 255
    im[:, :, 2] = 255.
    im = np.clip(im, 0, 255)
    im = im.astype('uint8')
    return cv2.cvtColor(im, cv2.COLOR_HSV2RGB)


def get_colors(n):
    from matplotlib import cm
    cmap = cm.get_cmap('jet')
    rgba = cmap(np.linspace(0, 1, n))
    return rgba


def variable_summaries(var):
    """Attach a lot of summaries to a Tensor (for TensorBoard visualization)."""
    with tf.name_scope('summaries'):
        mean = tf.reduce_mean(var)
        #         tf.summary.scalar('mean', mean)
        with tf.name_scope('stddev'):
            stddev = tf.sqrt(tf.reduce_mean(tf.square(var - mean)))
        tf.summary.scalar('stddev', stddev)

def db_info(self, dbType='val',train_type=0):
    self.init_train(train_type=train_type)
    self.pred = self.create_network()
    self.create_saver()
    val_info = []
    if train_type is 1:
        fname = os.path.join(self.conf.cachedir, self.conf.fulltrainfilename + '.tfrecords')
    else:
        if dbType is 'val':
            fname = os.path.join(self.conf.cachedir, self.conf.valfilename + '.tfrecords')
        else:
            fname = os.path.join(self.conf.cachedir, self.conf.trainfilename + '.tfrecords')
    num_val = count_records(fname)

    with tf.Session() as sess:
        start_at = self.init_and_restore(sess, True, ['loss', 'dist'])

        for step in range(num_val // self.conf.batch_size):
            if dbType is 'val':
                self.setup_val(sess)
            else:
                self.setup_train(sess)
            val_info.append(self.info)

    tf.reset_default_graph()
    return np.array(val_info).reshape([-1,2])


def analyze_gradients(loss, exclude, sess=None):
    # exclude should be a list and not a string
    var = tf.global_variables()
    tvar = []
    for vv in var:
        ix = max(map(vv.name.find,exclude))
        if ix < 0:
            tvar.append(vv)
    var = tvar
    gg = tf.gradients(loss,var)
    return gg, var


def compute_vals(op,n_steps):
    all = []
    for ndx in range(n_steps):
        a = op()
        all.append(a)
    all = np.array(all)
    all = np.reshape(all,(-1,)+all.shape[2:])
    return all

def count_records(filename):
    num = 0
    for record in tf.python_io.tf_record_iterator(filename):
        num += 1
    return num

def show_stack(im_s,xx,yy,cmap='gray'):
    import matplotlib.pyplot as plt
    from matplotlib import cm
    pad_amt = xx*yy - im_s.shape[0]
    if pad_amt > 0:
        im_s = np.concatenate([im_s,im_s[:pad_amt,...]],axis=0)
    isz1 = im_s.shape[1]
    isz2 = im_s.shape[2]
    im_s = im_s.reshape([xx,yy,isz1, isz2])
    im_s = im_s.transpose([0, 2, 1, 3])
    im_s = im_s.reshape([xx * isz1, yy * isz2])
    plt.figure(); plt.imshow(im_s,cmap=cmap)


def show_result(ims, ndx, locs, predlocs=None, hilitept=None, mft=None, perr=None, mrkrsz=10, fignum=11):
    import matplotlib.pyplot as plt
    from matplotlib import cm
    count = float(len(ndx))
    yy = np.ceil(np.sqrt(count/12)*4).astype('int')
    xx = np.ceil(count/yy).astype('int')
    f = plt.figure(num=fignum)
    f.clf()
    ax = f.subplots(xx,yy,sharex=True,sharey=True)  # figsize=(16,12),
    ax = ax.flatten()
    cmap = cm.get_cmap('jet')
    rgba = cmap(np.linspace(0, 1, locs.shape[1]))
    for idx in range(int(count)):
        if ims.shape[3] == 1:
            ax[idx].imshow(ims[ndx[idx],:,:,0],cmap='gray')
        else:
            ax[idx].imshow(ims[ndx[idx],...])

        if hilitept is not None:
            ax[idx].scatter(locs[ndx[idx], :, 0], locs[ndx[idx], :, 1],
                            c=rgba, marker='.', alpha=0.25)
            plt.sca(ax[idx])
            plt.plot(locs[ndx[idx], hilitept, 0], locs[ndx[idx], hilitept, 1],
                     c=rgba[hilitept,:], marker='.', markersize=12)
        else:
            ax[idx].scatter(locs[ndx[idx],:,0],locs[ndx[idx],:,1],c=rgba,marker='.', s=mrkrsz)
        if predlocs is not None:
            if hilitept is not None:
                ax[idx].scatter(predlocs[ndx[idx], :, 0], predlocs[ndx[idx], :, 1],
                                c=rgba, marker='+', alpha=0.25)
                #plt.sca(ax[idx])
                plt.plot(predlocs[ndx[idx], hilitept, 0], predlocs[ndx[idx], hilitept, 1],
                         c=rgba[hilitept,:], marker='+', markersize=12)
            else:
                ax[idx].scatter(predlocs[ndx[idx], :, 0], predlocs[ndx[idx], :, 1],
                                c=rgba, marker='+', s=mrkrsz)

        f.patch.set_facecolor((0.4, 0.4, 0.4))
        ax[idx].set_facecolor((1, 1, 1))

        tstr = "row {}".format(ndx[idx])
        if mft is not None:
            mov, frm, tgt = mft[ndx[idx], :]
            tstr += ": {}/{}/{}".format(mov, frm, tgt)
        if perr is not None and hilitept is not None:
            tstr += ": {:.3f}".format(perr[ndx[idx], hilitept])
        if len(tstr)>0:
            tobj = plt.title(tstr)
            plt.setp(tobj, color='w')

    return ax


def output_graph(logdir, sess):
    # sess = tf.get_default_session()
    train_writer = tf.summary.FileWriter(
        logdir,sess.graph)
    train_writer.add_summary(tf.Summary())


def get_timestamps(conf, info):
    L = h5py.File(conf.labelfile)
    pts = L['labeledposTS']
    ts_array  = []
    for ndx in range(pts.shape[1]):
        idx = np.array(L[pts[0, ndx]]['idx'])[0, :].astype('int') - 1
        val = np.array(L[pts[0, ndx]]['val'])[0, :] - 1
        sz = np.array(L[pts[0, ndx]]['size'])[:, 0].astype('int')
        Y = np.zeros(sz).flatten()
        Y[idx] = val
        Y = Y.reshape(np.flipud(sz))
        ts_array.append(Y)

    ts = np.zeros(info.shape[0:1])
    for ndx in range(info.shape[0]):
        cur_exp = info[ndx, 0].astype('int')
        cur_t = info[ndx,1].astype('int')
        cur_ts = ts_array[cur_exp][:,cur_t,:].max()
        ts[ndx] = cur_ts

    return ts


def tfrecord_to_coco(db_file, conf, img_dir, out_file, categories=None, scale = 1):

    # alice example category
    skeleton = [ [1,2],[1,3],[2,5],[3,4],[1,6],[6,7],[6,8],[6,10],[8,9],[10,11],[5,12],[9,13],[6,14],[6,15],[11,16],[4,17]]
    names = ['head','lneck','rneck','rshld','lshld','thrx','tail','lelb','lmid','relb','rmid','lfront','lmid','lrear','rrear','rmid','rfront']
    categories = [{'id': 1, 'skeleton': skeleton, 'keypoints': names, 'super_category': 'fly', 'name': 'fly'}]

    queue = tf.train.string_input_producer([db_file])
    data = multiResData.read_and_decode(queue, conf)
    n_records = count_records(db_file)

    bbox = [0,0,0,conf.imsz[0],conf.imsz[1],conf.imsz[0],conf.imsz[1],0]*scale
    area = conf.imsz[0]*conf.imsz[1]*scale*scale
    with tf.Session() as sess:
        coord = tf.train.Coordinator()
        threads = tf.train.start_queue_runners(sess=sess, coord=coord)

        ann = {'images':[], 'info':[], 'annotations':[],'categories':categories}
        for ndx in range(n_records):
            cur_im, cur_locs, cur_info = sess.run(data)
            if cur_im.shape[2] == 1:
                cur_im = cur_im[:,:,0]
            if scale is not 1:
                cur_im = transform.resize(cur_im, cur_im.shape[:2]*scale, preserve_range= True)
                cur_locs = scale*cur_locs
            im_name = '{:012d}.png'.format(ndx)
            misc.imsave(os.path.join(img_dir, im_name),cur_im)

            ann['images'].append({'id':ndx, 'width':conf.imsz[1]*scale, 'height':conf.imsz[0]*scale, 'file_name':im_name})
            ann['annotations'].append({'iscrowd':0,'segmentation':[bbox],'area':area,'image_id':ndx, 'id':ndx,'num_keypoints':conf.n_classes,'bbox':bbox,'keypoints':cur_locs.flatten().tolist(),'category_id':1})



        coord.request_stop()
        coord.join(threads)
    with open(out_file,'w') as f:
        json.dump(ann, f)
    # code to show skeleton.
    # plt.figure();
    # plt.imshow(cur_im, 'gray')
    # for b in skeleton:
    #     a = np.array(b) - 1
    #     plt.plot(cur_locs[a, 0], cur_locs[a, 1])


def create_imseq(ims, reverse=False,val_func=np.mean,sat_func=np.std):
    n_classes = ims.shape[0]
    ims = ims.astype('float')
    out_im = np.zeros(ims.shape[1:3] + (3,))
    if not reverse:
        out_im[:, :, 0] = np.argmax(ims, 0).astype('float32') / n_classes * 180
    else:
        out_im[:, :, 0] = np.argmin(ims, 0).astype('float32') / n_classes * 180

    zz = sat_func(ims,axis=0)
    out_im[:, :, 1] = zz/zz.max()
    out_im[:, :, 2] = val_func(ims,axis=0)
    out_im = np.clip(out_im, 0, 255)
    out_im = out_im.astype('uint8')
    return cv2.cvtColor(out_im, cv2.COLOR_HSV2RGB)


def crop_to_size(img, sz):
    # crops image to sz.
    new_sz = img.shape[:2]
    dx = sz[1] - new_sz[1]
    dy = sz[0] - new_sz[0]
    out_img = np.zeros(sz).astype(img.dtype)
    if dx < 0 or dy < 0:
        hdx = -int(dx/2)
        hdy = -int(dy/2)
        out_img[:,:,...] = img[hdy:(sz[0]+hdy),hdx:(sz[1]+hdx),...]
    else:
        hdx = int(dx/2)
        hdy = int(dy/2)
        out_img[hdy:(new_sz[0] + hdy), hdx:(new_sz[1] + hdx), ...] = img

        # if len(sz) == 2:
        #     out_img = np.pad(img,[[hdy,(dy-hdy)],[hdx,(dx-hdx)]],mode='edge')
        # else:
        #     out_img = np.pad(img,[[hdy,(dy-hdy)],[hdx,(dx-hdx)],[0,0]],mode='edge')

    return out_img, dx, dy


def preprocess_ims(ims, in_locs, conf, distort, scale, group_sz = 1):
    '''

    :param ims: Input image. It is converted to uint8 before applying the transformations. Size: B x H x W x C
    :param in_locs: 2D Location as B x N x 2
    :param conf: config object
    :param distort: To augment or not
    :param scale: How much to downsample the input image
    :param group_sz:
    :return:
    '''
#    assert ims.dtype == 'uint8', 'Preprocessing only work on uint8 images'
    locs = in_locs.copy()
    cur_im = ims.copy()
    cur_im = cur_im.astype('uint8')
    xs = adjust_contrast(cur_im, conf)
    xs, locs = scale_images(xs, locs, scale, conf)
    if distort:
        if conf.horz_flip:
            xs, locs = randomly_flip_lr(xs, locs, conf, group_sz=group_sz)
        if conf.vert_flip:
            xs, locs = randomly_flip_ud(xs, locs, conf, group_sz=group_sz)
        xs, locs = randomly_affine(xs, locs, conf, group_sz=group_sz)
        # xs, locs = randomly_scale(xs, locs, conf, group_sz=group_sz)
        # xs, locs = randomly_rotate(xs, locs, conf, group_sz=group_sz)
        # xs, locs = randomly_translate(xs, locs, conf, group_sz=group_sz)
        xs = randomly_adjust(xs, conf, group_sz=group_sz)
    xs = normalize_mean(xs, conf)
    return xs, locs


def pad_ims(ims, locs, pady, padx):
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
            out_ims[ex,:,:,c] = aa

    locs[...,0] += padx//2
    locs[...,1] += pady//2
    return out_ims, locs


def get_datestr():
    return datetime.datetime.now().strftime('%Y%m%d')


def running_in_docker():
    # KB 20190424: needed to check if this file exists, couldn't import in win/py3
    f_cgroup = '/proc/self/cgroup'
    if not os.path.isfile(f_cgroup):
        return False
    # From https://gist.github.com/anantkamath/623ce7f5432680749e087cf8cfba9b69
    with open(f_cgroup, 'r') as procfile:
        for line in procfile:
            fields = line.strip().split('/')
            if 'docker' in fields:
                return True
    return False


def json_load(filename):
    with open(filename,'r') as f:
        K = json.load(f)
    return K


def pickle_load(filename):
    with open(filename,'rb') as f:
        if sys.version_info.major > 2:
            K = pickle.load(f,encoding='latin1')
        else:
            K = pickle.load(f)
    return K


def yaml_load(filename):
    with open(filename,'r') as f:
        K = yaml.load(f)
    return K

def get_train_data_file(conf,name):
    if name == 'deepnet':
        train_data_file = os.path.join(conf.cachedir, 'traindata')
    else:
        train_data_file = os.path.join(conf.cachedir, conf.expname + '_' + name + '_traindata')
    return train_data_file


def get_last_epoch(conf, name):
    train_data_file = get_train_data_file(conf, name)
    if not os.path.exists(train_data_file):
        return None
    with open(train_data_file + '.json', 'r') as json_file:
        json_data = json.load(json_file)
    return int(json_data['step'][-1])


def get_latest_model_file_keras(conf, name):
    if name != 'deepnet':
        name = conf.expname + '_' + name
    last_epoch = get_last_epoch(conf, name)
    if last_epoch is None:
        return None
    save_epoch = last_epoch
    latest_model_file = os.path.join(conf.cachedir, name + '-{}'.format(save_epoch))
    if not os.path.exists(latest_model_file):
        save_epoch = int(np.floor(last_epoch/conf.save_step)*conf.save_step)
        latest_model_file = os.path.join(conf.cachedir, name + '-{}'.format(save_epoch))
        if not os.path.exists(latest_model_file):
            import glob
            files = glob.glob(os.path.join(conf.cachedir, "{}-[0-9]*").format(name))
            files.sort(key=os.path.getmtime)
            files = [f for f in files if os.path.splitext(f)[1] in ['.index', '']]
            aa = [int(re.search('-(\d*)', f).groups(0)[0]) for f in files]
            aa = [b - a for a, b in zip(aa[:-1], aa[1:])]
            if any([a < 0 for a in aa]):
                bb = int(np.where(np.array(aa) < 0)[0][-1]) + 1
                files = files[bb:]
            latest_model_file = files[-1]

    return  latest_model_file


def get_crop_loc(lbl,ndx,view, on_gt=False):
    ''' return crop loc in 0-indexed format
    For indexing add 1 to xhi and yhi.
    '''
    from APT_interface_mdn import read_entry
    # this is unnecessarily ugly just because matlab.
    if lbl['cropProjHasCrops'][0, 0] == 1:
        nviews = int(read_entry(lbl['cfg']['NumViews']))
        if on_gt:
            fname = 'movieFilesAllGTCropInfo'
        else:
            fname = 'movieFilesAllCropInfo'

        if nviews == 1:
            crop_loc = lbl[lbl[fname][0, ndx]]['roi'].value[:, 0].astype('int')
        else:
            crop_loc = lbl[lbl[lbl[fname][0, ndx]]['roi'][view][0]].value[:, 0].astype('int')
        crop_loc = crop_loc - 1
    else:
        crop_loc = None

    return crop_loc


def create_cum_plot(dd,d_max=None):
    d_max = dd.max() if d_max is None else d_max
    zz = np.linspace(0,d_max,100)
    cum_stats = []
    for ndx in range(dd.shape[1]):
        cum_stats.append([])
        for z in zz:
            cum_stats[ndx].append(np.count_nonzero(dd[:,ndx]<z))

    return np.array(cum_stats)


def datestr():
    import datetime
    return datetime.datetime.now().strftime('%Y%m%d')


def submit_job(name, cmd, dir,queue='gpu_any',gpu_model=None,timeout=12*60,run_dir='/groups/branson/home/kabram/bransonlab/APT/deepnet'):
    import subprocess
    sing_script = os.path.join(dir, 'opt_' + name + '.sh')
    sing_err = os.path.join(dir, 'opt_' + name + '.err')
    sing_log = os.path.join(dir, 'opt_' + name + '.log')
    bsub_script = os.path.join(dir, 'opt_' + name + '_bsub.sh')
    with open(sing_script, 'w') as f:
        f.write('#!/bin/bash\n')
        # f.write('bjobs -uall -m `hostname -s`\n')
        f.write('. /opt/venv/bin/activate\n')
        f.write('cd {}\n'.format(run_dir))
        f.write('numCores2use={} \n'.format(2))
        f.write('python {}'.format(cmd))
        f.write('\n')

    # KB 20190424: this doesn't work in py3
    os.chmod(sing_script, stat.S_IREAD|stat.S_IEXEC|stat.S_IWUSR)
    gpu_str = "num=1"
    if gpu_model is not None:
        gpu_str += ":gmodel={}".format(gpu_model)
    cmd = '''ssh 10.36.11.34 '. /misc/lsf/conf/profile.lsf; bsub -J {} -oo {} -eo {} -n2 -W {} -gpu "{}" -q {} "singularity exec --nv /misc/local/singularity/branson_cuda10_mayank.simg {}"' '''.format(name, sing_log, sing_err, timeout, gpu_str, queue, sing_script)  # -n2 because SciComp says we need 2 slots for the RAM
    with open(bsub_script,'w') as f:
        f.write(cmd)
        f.write('\n')

    subprocess.call(cmd, shell=True)
    print('Submitted jobs for {}'.format(name))
    print(cmd)


def read_h5_str(in_obj):
    return u''.join(chr(c) for c in in_obj)


def show_result_hist(im,loc,percs):
    from matplotlib import pyplot as plt
    cmap = get_cmap(percs.shape[0])
    f = plt.figure()
    if im.ndim == 2:
        plt.imshow(im,'gray')
    elif im.shape[2] == 1:
        plt.imshow(im[:,:,0],'gray')
    else:
        plt.imshow(im)

    ax = plt.gca()
    for pt in range(loc.shape[0]):
        for pp in range(percs.shape[0]):
            c = plt.Circle(loc[pt,:],percs[pp,pt],color=cmap[pp,:],fill=False)
            ax.add_patch(c)
