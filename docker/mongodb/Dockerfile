# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
# AUTHORS :  Emiliano Bruni (EB) <info@ebruni.it>
# DATE    :  2021-11-04
# PURPOSE :
#   Backend for Minion, a high performance job queue in [Perl](https://www.perl.org), derived from [Minion::Backend::Pg](https://metacpan.org/pod/Minion::Backend::Pg) with supports for all its features .
#
#   This image is published in docker hub with handle: ebruni/minion-backend-mongodb
#
# USAGE:
#   docker build -t minion-backend-mongodb .
#
# UPDATES:
#   AUTHOR  DATE        VER  COMMENTS
#   EB      2021-11-04  1.2  Update backend to v.1.12
#   EB      2021-09-24  1.1  Update backend to v.1.10
#   EB      2021-09-09  1.0  Initial Version
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#

#
# this file is generated via docker-builder
#
# do not edit it directly
#
FROM ebruni/mojolicious:minion-mongodb
MAINTAINER Emiliano Bruni <info@ebruni.it>

WORKDIR /var/www


RUN apk update && apk add --no-cache \
    make \
    gcc \
    perl-dev \
    musl-dev \
  && cpanm --no-wget -n \
    Minion::Backend::MongoDB \
  && rm -r /root/.cpanm \
  && apk del \
    make \
    gcc \
    perl-dev \
    musl-dev \
  && true

ARG NOW=not-set
LABEL org.opencontainers.image.authors="Emiliano Bruni <info@ebruni.it>"
LABEL org.opencontainers.image.created=$NOW
LABEL org.opencontainers.image.description="backend for Minion, a high performance job queue in Perl, derived from Minion::Backend::Pg with supports for all its features ."
LABEL org.opencontainers.image.documentation=https://github.com/avkhozov/Minion-Backend-MongoDB/blob/master/README.pod
LABEL org.opencontainers.image.licenses=Artistic-2.0
LABEL org.opencontainers.image.source=https://github.com/avkhozov/Minion-Backend-MongoDB/blob/master/mongodb/Dockerfile
LABEL org.opencontainers.image.title=Minion::Backend::MongoDB
LABEL org.opencontainers.image.url=https://github.com/avkhozov/Minion-Backend-MongoDB
LABEL org.opencontainers.image.version=1.1-mongodb

CMD ["/bin/bash", "-c"]
