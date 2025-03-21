<!-- this file is generated via docker-builder, do not edit it directly -->


# What is Minion::Backend::MongoDB?

Minion::Backend::MongoDB is a backend for Minion, a high performance job queue in [Perl](https://www.perl.org), derived from [Minion::Backend::Pg](https://metacpan.org/pod/Minion::Backend::Pg) with supports for all its features .

All images, unless explicitly defined, are based on [ebruni/mojolicious:minion](https://hub.docker.com/repository/docker/ebruni/mojolicious) and provide installed together with these Perl modules:

* [Minion::Backend::MongoDB](https://metacpan.org/pod/Minion::Backend::MongoDB) v1.14.

# Supported tags and respective Dockerfile links

* Minion::Backend::MongoDB: [1.6, latest (main/Dockerfile)](https://github.com/avkhozov/Minion-Backend-MongoDB/blob/master/main/Dockerfile) (size: **106MB**)

* Minion::Backend::MongoDB: [1.6-mongodb, mongodb (mongodb/Dockerfile)](https://github.com/avkhozov/Minion-Backend-MongoDB/blob/master/mongodb/Dockerfile) (size: **106MB**) based on [ebruni/mojolicious:minion-mongodb](https://hub.docker.com/repository/docker/ebruni/mojolicious) 
# How to use this image

    $ docker container run --rm -ti ebruni/minion-backend-mongodb /bin/ash

# Authors

Emiliano Bruni (EB) <info@ebruni.it>

# Changes

| AUTHOR | DATE | VER. | COMMENTS |
|:---|:---:|:---:|:---|
| EB | 2025-03-21 | 1.6 | Updated to alpine 3.20. Mojolicious to v. 9.38 |
| EB | 2022-06-07 | 1.5 | Update to Mojolicious v.9.26 |
| EB | 2022-02-24 | 1.4 | Update Backend to v.1.14 |
| EB | 2022-01-17 | 1.3 | Update Backend to v.1.13 |
| EB | 2021-11-04 | 1.2 | Update Backend to v.1.12 |
| EB | 2021-09-24 | 1.1 | Update Backend to v.1.10 |
| EB | 2021-09-09 | 1.0 | Initial Version |

# Source

The source of this image on [GitHub](https://github.com/avkhozov/Minion-Backend-MongoDB).
