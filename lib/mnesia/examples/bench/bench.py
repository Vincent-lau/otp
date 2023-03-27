#! /bin/usr/env python3

from jinja2 import Environment, FileSystemLoader
import os,socket


log_file = '~/proj/hypermnesia/benchmark/foo4.txt'
# log_file = '/dev/null'

n_replicas = 3
table_nodes = [f'bench{i}@{socket.gethostname()}' for i in range(1, n_replicas + 1)]
default_params = {
    'activity': 'async_dirty',
    'generator_profile': 'rw_ratio',
    'rw_ratio': 0.5,
    'statistics_detail': 'debug',
    'generator_warmup': 12000,
    'generator_duration': 90000,
    'generator_cooldown': 12000,
    'generator_nodes': table_nodes,
    'n_generators_per_node': 1,
    'table_nodes': table_nodes,
    'n_replicas': n_replicas,
    'n_subscribers': 5000,
}


def change_nodes(n_replicas: int) -> dict():
    table_nodes = [f'bench{i}@{socket.gethostname()}' for i in range(1, n_replicas + 1)]
    params = default_params.copy()
    params['table_nodes'] = table_nodes
    params['generator_nodes'] = table_nodes
    params['n_replicas'] = n_replicas

    return params


def change_activity(activity: str) -> dict():
    params = default_params.copy()
    params['activity'] = activity


    return params


def change_profile(profile: str, ratio = 0.0) -> dict():
    params = default_params.copy()
    params['generator_profile'] = profile
    if profile == 'rw_ratio':
        params['rw_ratio'] = ratio
    return params


def gen_config(params):

    environment = Environment(loader=FileSystemLoader("./"))
    template = environment.get_template("bench.config.jinja2")

    filename = "bench0.config"
    content = template.render(
        activity=params['activity'],
        generator_profile=params['generator_profile'],
        rw_ratio=params['rw_ratio'],
        generator_warmup=params['generator_warmup'],
        generator_duration=params['generator_duration'],
        generator_cooldown=params['generator_cooldown'],
        statistics_detail=params['statistics_detail'],
        generator_nodes=params['generator_nodes'],
        n_generators_per_node=params['n_generators_per_node'],
        table_nodes=params['table_nodes'],
        n_replicas=params['n_replicas'],
        n_subscribers=params['n_subscribers'],
    )
    with open(filename, mode="w", encoding="utf-8") as message:
        message.write(content)
        print(f"... wrote {filename}")


def main():
    for i in [i * 0.1 for i in range(1, 11)]:
        params = change_profile('rw_ratio', i)
        gen_config(params)
        os.system(f'echo >> {log_file}')
        os.system(f'echo >> {log_file}')
        os.system(
            f'echo ================================================================================ >> {log_file}')
        os.system(f'date >> {log_file}')
        os.system(f'./bench.sh bench0.config | tee -a {log_file}')


if __name__ == "__main__":
    main()
