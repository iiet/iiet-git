#!/bin/sh
bundle install -j2 --deployment --without development test mysql aws kerberos
