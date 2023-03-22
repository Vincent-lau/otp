#! /bin/usr/env python3

from jinja2 import Environment, FileSystemLoader
import os


log_file = '~/proj/hypermnesia/benchmark/foo1.txt'

n_replicas = 3
table_nodes = [f'bench{i}@vincent-pc' for i in range(1, n_replicas + 1)]
default_params = {
    'activity': 'transaction',
    'generator_profile': 't2',
    'generator_nodes': ['bench1@vincent-pc'],
    'table_nodes': table_nodes,
    'n_replicas': 3,
    'n_subscribers': 5000,
}


def change_nodes(n_replicas: int) -> dict():
    table_nodes = [f'bench{i}@vincent-pc' for i in range(1, n_replicas + 1)]
    params = default_params.copy()
    params['table_nodes'] = table_nodes
    params['n_replicas'] = n_replicas
    if n_replicas > 1:
        params['generator_nodes'] = [f'bench{i}@vincent-pc' for i in range(1, 3)]

    return params

def change_activity(activity: str) -> dict():
    params = default_params.copy()
    params['activity'] = activity
    if n_replicas > 1:
        params['generator_nodes'] = [f'bench{i}@vincent-pc' for i in range(1, 3)]

    return params


def gen_config(params):

    environment = Environment(loader=FileSystemLoader("./"))
    template = environment.get_template("bench.config.jinja2")

    filename = "bench0.config"
    content = template.render(
        activity = params['activity'],
        generator_profile=params['generator_profile'],
        table_nodes=params['table_nodes'],
        generator_nodes=params['generator_nodes'],
        n_replicas=params['n_replicas'],
        n_subscribers=params['n_subscribers'],
    )
    with open(filename, mode="w", encoding="utf-8") as message:
        message.write(content)
        print(f"... wrote {filename}")


def main():
    for i in range(3, 5, 2):
        params = change_nodes(i)
        gen_config(params)
        os.system(f'echo ================================================================================ >> {log_file}')
        os.system(f'date >> {log_file}')
        os.system(f'./bench.sh bench0.config | tee -a {log_file}')


if __name__ == "__main__":
    main()
