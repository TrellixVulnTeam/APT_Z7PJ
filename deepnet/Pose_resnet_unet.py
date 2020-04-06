from PoseBase import PoseBase
import PoseTools
import os
import tarfile
import tensorflow as tf
import tensorflow.contrib.slim as slim
import urllib
import resnet_official
from tensorflow.contrib.slim.nets import resnet_v1
import convNetBase as CNB
from PoseCommon_dataset import conv_relu3, conv_relu


class Pose_resnet_unet(PoseBase):

    def __init__(self, conf):
        PoseBase.__init__(self, conf,hmaps_downsample=1)

        self.conf.use_pretrained_weights = True

        self.resnet_source = self.conf.get('mdn_resnet_source','slim')
        if self.resnet_source == 'official_tf':
            url = 'http://download.tensorflow.org/models/official/20181001_resnet/savedmodels/resnet_v2_fp32_savedmodel_NHWC.tar.gz'
            script_dir = os.path.dirname(os.path.realpath(__file__))
            wt_dir = os.path.join(script_dir,'pretrained')
            wt_file = os.path.join(wt_dir,'resnet_v2_fp32_savedmodel_NHWC','1538687283','variables','variables.index')
            if not os.path.exists(wt_file):
                print('Downloading pretrained weights..')
                if not os.path.exists(wt_dir):
                    os.makedirs(wt_dir)
                sname, header = urllib.urlretrieve(url)
                tar = tarfile.open(sname, "r:gz")
                print('Extracting pretrained weights..')
                tar.extractall(path=wt_dir)
            self.pretrained_weights = os.path.join(wt_dir,'resnet_v2_fp32_savedmodel_NHWC','1538687283','variables','variables')
        else:
            url = 'http://download.tensorflow.org/models/resnet_v1_50_2016_08_28.tar.gz'
            script_dir = os.path.dirname(os.path.realpath(__file__))
            wt_dir = os.path.join(script_dir,'pretrained')
            wt_file = os.path.join(wt_dir,'resnet_v1_50.ckpt')
            if not os.path.exists(wt_file):
                print('Downloading pretrained weights..')
                if not os.path.exists(wt_dir):
                    os.makedirs(wt_dir)
                sname, header = urllib.urlretrieve(url)
                tar = tarfile.open(sname, "r:gz")
                print('Extracting pretrained weights..')
                tar.extractall(path=wt_dir)
            self.pretrained_weights = os.path.join(wt_dir,'resnet_v1_50.ckpt')


    def create_network(self):

        conv = lambda a, b: conv_relu3( a,b,self.ph['phase_train'])

        im, locs, info, hmap = self.inputs

        if self.resnet_source == 'slim':
            with slim.arg_scope(resnet_v1.resnet_arg_scope()):
                net, end_points = resnet_v1.resnet_v1_50(im,
                                          global_pool=False, is_training=self.ph[
                                          'phase_train'])
                l_names = ['conv1', 'block1/unit_2/bottleneck_v1', 'block2/unit_3/bottleneck_v1',
                           'block3/unit_5/bottleneck_v1', 'block4']
                down_layers = [end_points['resnet_v1_50/' + x] for x in l_names]

                ex_down_layers = conv(self.inputs[0], 64)
                down_layers.insert(0, ex_down_layers)
                n_filts = [32, 64, 64, 128, 256, 512]

        elif self.resnet_source == 'official_tf':
            mm = resnet_official.Model( resnet_size=50, bottleneck=True, num_classes=17, num_filters=32, kernel_size=7, conv_stride=2, first_pool_size=3, first_pool_stride=2, block_sizes=[3, 4, 6, 3], block_strides=[2, 2, 2, 2], final_size=2048, resnet_version=2, data_format='channels_last',dtype=tf.float32)
            im = tf.placeholder(tf.float32, [8, 512, 512, 3])
            resnet_out = mm(im, True)
            down_layers = mm.layers
            ex_down_layers = conv(self.inputs[0], 64)
            down_layers.insert(0, ex_down_layers)
            n_filts = [32, 64, 64, 128, 256, 512, 1024]


        prev_in = None
        for ndx in reversed(range(len(down_layers))):

            if prev_in is None:
                X = down_layers[ndx]
            else:
                X = tf.concat([prev_in, down_layers[ndx]],axis=-1)

            sc_name = 'layerup_{}_0'.format(ndx)
            with tf.variable_scope(sc_name):
                X = conv(X, n_filts[ndx])

            if ndx is not 0:
                sc_name = 'layerup_{}_1'.format(ndx)
                with tf.variable_scope(sc_name):
                    X = conv(X, n_filts[ndx])

                layers_sz = down_layers[ndx-1].get_shape().as_list()[1:3]
                with tf.variable_scope('u_{}'.format(ndx)):
                    X = CNB.upscale('u_{}'.format(ndx), X, layers_sz)

            prev_in = X

        n_filt = X.get_shape().as_list()[-1]
        n_out = self.conf.n_classes
        weights = tf.get_variable("out_weights", [3,3,n_filt,n_out],
                                  initializer=tf.contrib.layers.xavier_initializer())
        biases = tf.get_variable("out_biases", n_out,
                                 initializer=tf.constant_initializer(0.))
        conv = tf.nn.conv2d(X, weights, strides=[1, 1, 1, 1], padding='SAME')
        X = tf.add(conv, biases, name = 'unet_pred')
        X = 2*tf.sigmoid(X)-1
        return X
